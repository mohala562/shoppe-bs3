class OrdersController < ApplicationController
  
  before_filter(:except => :status) { redirect_to root_path unless has_order? }
  
  def status
    @order = Shoppe::Order.find_by_token!(params[:token])
  end
  
  def destroy
    current_order.destroy
    session[:order_id] = nil
    respond_to do |wants|
      wants.html { redirect_to root_path, :notice => "Your basket has been emptied successfully."}
      wants.json do
        flash[:notice] = "Your shopping bag is now empty."
        render :json => {:status => 'complete', :redirect => root_path}
      end
    end
  end
  
  def remove_item
    item = current_order.order_items.find(params[:order_item_id])
    if current_order.order_items.count == 1
      destroy
    else
      item.remove
      respond_to do |wants|
        wants.html { redirect_to request.referer, :notice => "Item has been removed from your basket successfully"}
        wants.json do
          current_order.reload
          render :json => {:status => 'complete', :items => render_to_string(:partial => 'shared/order_items.html', :locals => {:order => current_order})}
        end
      end
    end
  end
  
  def change_item_quantity
    item = current_order.order_items.find(params[:order_item_id])
    request.delete? ? item.decrease! : item.increase!
    respond_to do |wants|
      wants.html { redirect_to request.referer || root_path, :notice => "Quantity has been updated successfully." }
      wants.json do
        current_order.reload
        if current_order.empty?
          destroy
        else
          render :json => {:status => 'complete', :items => render_to_string(:partial => 'shared/order_items.html', :locals => {:order => current_order})}
        end
      end
    end    
  rescue Shoppe::Errors::NotEnoughStock => e
    respond_to do |wants|
      wants.html { redirect_to request.referer, :alert => "Unfortunately, we don't have enough stock. We only have #{e.available_stock} items available at the moment. Please get in touch though, we're always receiving new stock." }
      wants.json { render :json => {:status => 'error', :message => "Unfortunateley, we don't have enough stock to add more items."} }
    end
  end

  def change_delivery_service
    if current_order.delivery_service = current_order.available_delivery_services.select { |s| s.id == params[:delivery_service].to_i}.first
      current_order.save
      respond_to do |wants|
        wants.html { redirect_to request.referer, :notice => "Delivery service has been changed"}
        wants.json do
          current_order.reload
          render :json => {:status => 'complete', :items => render_to_string(:partial => 'shared/order_items.html', :locals => {:order => current_order})}
        end
      end
    else
      respond_to do |wants|
        wants.html { redirect_to request.referer, :alert => "You cannot select this delivery method."}
        wants.json { render :json => {:status => 'error', :message => 'InvalidDeliveryMethod'}, :status => 422 }
      end
    end
  end
  
  def checkout
    @order = Shoppe::Order.find(current_order.id)
    if request.patch?
      @order.attributes = params[:order].permit(:first_name, :last_name, :company, :billing_address1, :billing_address2, :billing_address3, :billing_address4, :billing_country_id, :billing_postcode, :email_address, :phone_number, :delivery_name, :delivery_address1, :delivery_address2, :delivery_address3, :delivery_address4, :delivery_postcode, :delivery_country_id, :separate_delivery_address)
      @order.ip_address = request.ip
      if @order.proceed_to_confirm
        redirect_to checkout_payment_path
      end
    end
  end

  def payment
    @order = Shoppe::Order.find(current_order.id)
    if request.post?
      if @order.accept_stripe_token(params[:stripe_token])
        redirect_to checkout_confirmation_path
      else
        flash.now[:notice] = "Could not exchange Stripe token. Please try again."
      end
    end
  end

  
  def confirmation
    unless current_order.confirming?
      redirect_to checkout_path
      return
    end
    
    if request.patch?
      begin
        current_order.confirm!
        # This payment method should usually be called in a payment module or elsewhere but for the demo
        # we are adding a payment to the order straight away.
        current_order.payments.create(:method => "Credit Card", :amount => current_order.total, :reference => rand(10000) + 10000, :refundable => true)
        session[:order_id] = nil
        redirect_to root_path, :notice => "Order has been placed!"

        # Fire off to Xero and create invoice (marked as paid)
        # TODO

      rescue Shoppe::Errors::PaymentDeclined => e
        flash[:alert] = "Payment was declined by the bank. #{e.message}"
        redirect_to checkout_path
      rescue Shoppe::Errors::InsufficientStockToFulfil
        flash[:alert] = "We're terribly sorry but while you were checking out we ran out of stock of some of the items in your basket. Your basket has been updated with the maximum we can currently supply. If you wish to continue just use the button below."
        redirect_to checkout_path
      end
    end
  end

  def create_payment_in_xero
    payment = @client.Payment.build invoice: {id: @invoice.id},
                                    account: {code: 100},
                                    date: Date.today,
                                    amount: @invoice.amount_due,
                                    reference: "Invoice #{@invoice.id}"
    payment.save
  end

  def download_invoice_from_xero
    invoice = @client.Invoice.find(params[:id])
    send_data invoice.pdf, type: "application/pdf", filename: "Invoice #{invoice.invoice_number}"
  end

  def complete_purchase
    @invoice = @client.Invoice.find(params[:id])
    create_stripe_customer if !current_registry.has_stripe? and params[:auto_charge]
    update_customer_credit_card if current_registry.has_stripe? and params[:auto_charge]
    payment_details = {amount: (@invoice.amount_due * 100).to_i, currency: "gbp", description: "Pay for invoice #{@invoice.invoice_number}"}
    payment_details.merge! params[:auto_charge] ? { customer: current_registry.stripe_customer_id } : { card: params[:stripe_card_token] }

    @response = Stripe::Charge.create payment_details
    @xero_response = create_payment_in_xero if @response['paid']
  end
    
end
