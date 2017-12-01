require 'dotenv'
Dotenv.load
require 'sinatra/base'
require 'json'
require 'httparty'
require 'resque'
require 'shopify_api'
require 'active_support/core_ext'
require 'sinatra/activerecord'

#Dir[File.dirname(__FILE__) + '/models/*.rb'].each {|file| require file }
require_relative 'models/model'
require_relative 'recharge_api'
require_relative 'logging'
require_relative 'resque_helper'
require_relative 'resque_change_sizes'

class HandlerError < StandardError
  DEFAULT_HEADERS = {}
  attr_accessor :headers, :status

  def initialize(msg, options)
    @status = options[:status] ? options[:status] : 500
    @headers = options[:headers] ? options[:headers] : DEFAULT_HEADERS
    
    super(msg)
  end

  def response
    [status, headers, message]
  end
end

class EllieListener < Sinatra::Base
  register Sinatra::ActiveRecordExtension
  include Logging

  PAGE_LIMIT = 250

  configure do

    enable :logging
    set :server, :puma
    #set :protection, :except => [:json_csrf]

    mime_type :application_javascript, 'application/javascript'
    mime_type :application_json, 'application/json'
  end

  def initialize
    @tokens = {}
    @key = ENV['SHOPIFY_API_KEY']
    @secret = ENV['SHOPIFY_SHARED_SECRET']
    @app_url = 'www.ellieactivesportshelp.com'
    @default_headers = { 'Content-Type' => 'application/json' }
    @recharge_token = ENV['RECHARGE_ACCESS_TOKEN']
    @recharge_change_header = {
      "X-Recharge-Access-Token" => @recharge_token,
      "Accept" => "application/json",
      "Content-Type" =>"application/json"
    }

    super
  end

  get '/install' do
    shop = 'ellieactive.myshopify.com'
    scopes = 'read_orders, write_orders, read_products, read_customers, write_customers'

    # construct the installation URL and redirect the merchant
    install_url =
      "http://#{shop}/admin/oauth/authorize?client_id=#{@key}&scope=#{scopes}"\
      "&redirect_uri=http://#{@app_url}/auth/shopify/callback"

    redirect install_url
  end


  get '/auth/shopify/callback' do
    # extract shop data from request parameters
    shop = request.params['shop']
    code = request.params['code']
    hmac = request.params['hmac']

    # perform hmac validation to determine if the request is coming from Shopify
    h = request.params.reject{|k,_| k == 'hmac' || k == 'signature'}
    query = URI.escape(h.sort.collect{|k,v| "#{k}=#{v}"}.join('&'))
    digest = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), @secret, query)

    unless hmac == digest
      return [403, "Authentication failed. Digest provided was: #{digest}"]
    end

    # if we don't have an access token for this particular shop,
    # we'll post the OAuth request and receive the token in the response
    if @tokens[shop].nil?
      url = "https://#{shop}/admin/oauth/access_token"

      payload = {
        client_id: @key,
        client_secret: @secret,
        code: code
      }

      response = HTTParty.post(url, body: payload)

      # if the response is successful, obtain the token and store it in a hash
      if response.code == 200
        @tokens[shop] = response['access_token']
      else
        return [500, 'Something went wrong.']
      end
    end

    # now that we have the token, we can instantiate a session
    session = ShopifyAPI::Session.new(shop, @tokens[shop])
    @my_session = session
    ShopifyAPI::Base.activate_session(session)

    # create webhook for order creation if it doesn't exist



    redirect '/hello'

  end

  get '/hello' do
    'Hello, success, thanks for installing me!'
  end

  get '/test' do
    'Hi there endpoint is active'
  end

  get '/subscriptions' do
    shopify_id = params['shopify_id']
    logger.debug params.inspect
    if shopify_id.nil?
      return [400, @default_headers, JSON.generate(error: 'shopify_id required')]
    end
    customer_id = Customer.find_by(shopify_customer_id: shopify_id).try(:customer_id)
    return [404, @default_headers, {error: 'not found'}.to_json] if customer_id.nil?
    data = Subscription.where(
        status: 'ACTIVE',
        shopify_product_id: Subscription::CURRENT_PRODUCTS.pluck(:id),
        customer_id: customer_id,
    )
    output = data.map{|sub| transform_subscriptions(sub, sub.orders)}
    [200, @default_headers, output.to_json]
  end

  get '/subscription/:subscription_id/sizes' do |subscription_id|
    sub = Subscription.find subscription_id
    #sub = Subscription.limit(200).sample
    return [404, @default_headers, {error: 'subscription not found'}.to_json] if sub.nil?
    [200, @default_headers, sub.sizes.to_json]
  end

  post '/subscriptions' do
    json = JSON.parse request.body.read
    shopify_id = json['shopify_id']
    if shopify_id.nil?
      return [400, JSON.generate({error: 'shopify_id required'})]
    end
    data = Customer.joins(:subscriptions)
      .find_by(shopify_customer_id: shopify_id, status: 'ACTIVE')
      .subscriptions
      .map{|sub| [sub, sub.orders]}
    output = data.map{|i| transform_subscriptions(*i)}
    [200, @default_headers, output.to_json]
  end

  get '/subscription/:subscription_id' do |subscription_id|
    subscription = Subscription.find(subscription_id)
    [200, @default_headers, subscription.to_json]
  end

  put '/subscription/:subscription_id/sizes' do |subscription_id|
    #puts 'found the method'
    # body parsing and validation
    begin
      json = JSON.parse request.body.read
      sizes = json.select do |key, val|
        SubLineItem::SIZE_PROPERTIES.include?(key) && SubLineItem::SIZE_VALUES.include?(val)
      end
      logger.debug "sizes: #{sizes}"
    rescue Exception => e
      logger.error e.inspect
      return [400, @default_headers, {error: e}.to_json]
    end
    begin
      #res = RechargeAPI.put("/subscriptions/#{subscription_id}", {body: body_json})
      #queued = Subscription.async(:recharge_update, body)
      #ChangeSizes.perform(subscription_id, sizes)
      queued = Resque.enqueue(ChangeSizes, subscription_id, sizes)
      raise 'Error updating sizes. Please try again later.' unless queued
      #line_items.each(&:save!)
    rescue Exception => e
      logger.error e.inspect
      return [500, @default_headers, {error: e}.to_json]
    end
    [200, @default_headers, sizes.to_json]
  end

  put '/subscription/:subscription_id' do |subscription_id|
    subscription = Subscription.find_by(subscription_id: subscription_id)
    if subscription.nil?
      return [400, @default_headers, {error: 'subscription not found'}.to_json]
    end
    begin
      json = JSON.parse request.body.read
      matching_keys = (subscription.API_MAP.pluck(:remote_keys) & json.keys)
      subscription.update(json.select { |k, _| matching_keys.include? k })
    rescue
      return [400, @default_headers, {error: 'invalid payload data'}.to_json]
    end
    begin
      res = Subscription.async(:recharge_update, subscription.as_recharge)
      raise 'Error processing subscription change. Please try again later.' unless res
      subscription.save
    rescue StandardError => e
      logger.error e.inspect
      return [500, @default_headers, {error: e}.to_json]
    end
    output = {subscription: subscription}
    [200, @default_headers, output.to_json]
  end

  post '/subscription/:subscription_id/skip' do |subscription_id|
    sub = Subscription.find subscription_id
    return [400, @default_headers, {error: 'subscription not found'}.to_json] if sub.nil?
    begin
      request_body = JSON.parse request.body.read
      puts "request_body = #{request_body}"
    rescue StandardError => e
      return [400, @default_headers, {error: 'invalid payload data', details: e}.to_json]
    end
    skip_res = sub.skip
    # FIXME: currently does not allow skipping prepaid subscriptions
    queue_res = Subscription.async :skip!, subscription_id
    if queue_res
      SkipReason.create(
        customer_id: sub.customer.customer_id,
        shopify_customer_id: request_body['shopify_customer_id'],
        subscription_id: sub.subscription_id,
        charge_id: sub.charges.next_scheduled,
        skipped_to: sub.next_charge_scheduled_at,
        skip_status: skip_res,
        reason: request_body['reason'],
      )
      [200, @default_headers, {skipped: skip_res, subscription: sub.as_recharge}.to_json]
    else
      [500, @default_headers, {error: 'error processing skip'}.to_json]
    end
  end

  # demo endpoints for customers

  get '/customers' do
    customers = params.empty? ? Customer.all : Customer.where(params)
    output = customers.map(&:as_recharge).to_json
    [200, @default_headers, output]
  end

  get '/customers/:customer_id' do |customer_id|
    customer = Customer.find(customer_id)
    customer.recharge_update!
    output = customer.as_recharge.to_json
    [200, @default_headers, output]
  end

  put '/customer/:customer_id' do |customer_id|
    json = JSON.parse request.body
    json['customer_id'] = customer_id
    res = Customer.async.update_recharge(json)
    customer = Customer.from_recharge json
    if res && customer.errors.empty?
      [200, @default_headers, customer.as_recharge.to_json]
    else
      error = {
        error: 'invalid customer data',
        details: customer.errors
      }
      [400, @default_headers, error.to_json]
    end
  end

  put '/subscription_switch' do
    puts 'Received stuff'
    puts params.inspect
    puts '----------'
    myjson = params  
    
    puts "recharge_change_header = #{@recharge_change_header}"

    #myjson = JSON.parse(request.body.read)
    myjson['recharge_change_header'] = @recharge_change_header
    puts myjson.inspect
    my_action = myjson['action']
    if my_action == 'switch_product'
      Resque.enqueue(SubscriptionSwitch, myjson)
    else
      puts "Can't switch product, action must be switch product not #{my_action}"
    end

  end

  post '/subscription_skip' do
    puts "Received skip request"
    puts params.inspect
    params['recharge_change_header'] = @recharge_change_header
    my_action = params['action']
    my_now = Date.today.day
    puts "Day of the month is #{my_now}"
    if my_now < 5
      if my_action == "skip_month"
        Resque.enqueue(SubscriptionSkip, params)
      else
        puts "Cannot skip this product, action must be skip_month not #{my_action}"
      end
    else
      puts "It is past the 4th of the month, cannot skip"
    end

  end

  get '/skippable_subscriptions' do
    shopify_id = params['shopify_id']
    logger.debug params.inspect
    if shopify_id.nil?
      return [400, @default_headers, JSON.generate(error: 'shopify_id required')]
    end
    customer = Customer.joins(:subscriptions)
      .find_by(shopify_customer_id: shopify_id, status: 'ACTIVE')
    return [404, @default_headers, {error: 'customer not found'}] if customer.nil?
    next_charge_sql = 'next_charge_scheduled_at > ? AND next_charge_scheduled_at < ?'
    data = customer
      .subscriptions
      .skippable_products
      .where(status: 'ACTIVE')
      .where(next_charge_sql, Date.today.beginning_of_month, Date.today.end_of_month)
      .map do |sub|
        skippable = sub.skippable?
        {
          subscription_id: sub.subscription_id,
          shopify_product_title: sub.product_title,
          shopify_product_id: sub.shopify_product_id,
          next_charge_scheduled_at: sub.next_charge_scheduled_at.strftime('%F'),
          skippable: skippable,
          can_choose_alt_product: skippable,
        }
      end
    [200, @default_headers, data.to_json]
  end

  class SubscriptionSkip
    extend ResqueHelper
    @queue = "skip_product"
    def self.perform(params)
      update_success = false
      Resque.logger = Logger.new("#{Dir.getwd}/logs/skip_resque.log")
      puts "Got this: #{params.inspect}"
      #POST /subscriptions/<subscription_id>/set_next_charge_date
      subscription_id = params['subscription_id']
      shopify_customer_id = params['shopify_customer_id']
      my_reason = params['reason']
      my_sub = Subscription.find(subscription_id)
      my_customer = Customer.find_by(shopify_customer_id: shopify_customer_id)
      my_customer_id = my_customer.customer_id

      begin
        
        my_now = Date.today
        puts my_sub.inspect
        temp_next_charge = my_sub.next_charge_scheduled_at.to_s
        puts temp_next_charge
        my_next_charge = my_sub.try(:next_charge_scheduled_at).try('+', 1.month)
        #my_next_charge = my_next_charge >> 1
        puts "Now next charge date = #{my_next_charge.inspect}"
        next_charge_str = my_next_charge.strftime("%Y-%m-%d")
        puts "We will change the next_charge_scheduled_at to: #{next_charge_str}"
        recharge_change_header = params['recharge_change_header']
        body = {"date" => next_charge_str}.to_json
        puts "Pushing new charge_date to ReCharge: #{body}"
        my_update_sub = HTTParty.post("https://api.rechargeapps.com/subscriptions/#{subscription_id}/set_next_charge_date", :headers => recharge_change_header, :body => body, :timeout => 80)
        update_success = my_update_sub.success?
        puts my_update_sub.inspect
        Resque.logger.info(my_update_sub.inspect)
      rescue Exception => e
        Resque.logger.error(e.inspect)
      end

      update_success = true
      puts "****** Hooray We have no errors **********"
      Resque.logger.info("****** Hooray We have no errors **********")
      puts "We are adding to skip_reasons table"
      skip_reason = SkipReason.create(customer_id:  my_customer_id, shopify_customer_id:  shopify_customer_id, subscription_id:  subscription_id, reason:  my_reason, skipped_to:  next_charge_str, skip_status:  update_success, created_at:  my_now )
      puts skip_reason.inspect
      puts "We were not able to update the subscription" unless update_success
      Resque.logger.info("We were not able to update the subscription") unless update_success

      
    end
  end

  class SubscriptionSwitch
    extend ResqueHelper
    @queue = "switch_product"
    def self.perform(params)
      #puts params.inspect
      Resque.logger = Logger.new("#{Dir.getwd}/logs/resque.log")
  
      #{"action"=>"switch_product", "subscription_id"=>"8672750", "product_id"=>"8204555081"}
      subscription_id = params['subscription_id']
      product_id = params['product_id']
      puts "We are working on subscription #{subscription_id}"
      Resque.logger.info("We are working on subscription #{subscription_id}")
  
      temp_hash = provide_alt_products(product_id)
      puts temp_hash
      Resque.logger.info("new product info for subscription #{subscription_id} is #{temp_hash}")
  
      recharge_change_header = params['recharge_change_header']
      puts recharge_change_header
      body = temp_hash.to_json
  
      puts body
      #puts "Got here hoser"
  
  
  
      my_update_sub = HTTParty.put("https://api.rechargeapps.com/subscriptions/#{subscription_id}", :headers => recharge_change_header, :body => body, :timeout => 80)
      puts my_update_sub.inspect
      Resque.logger.info(my_update_sub.inspect)
  
  
      update_success = false
      if my_update_sub.code == 200
        update_success = true
        puts "****** Hooray We have no errors **********"
        Resque.logger.info("****** Hooray We have no errors **********")
      else
        puts "We were not able to update the subscription"
        Resque.logger.info("We were not able to update the subscription")
      end
  
  
    end
  end
  

  private

  def transform_subscriptions(sub, orders)
    logger.debug "subscription: #{sub.inspect}"
    { 
      shopify_product_id: sub.shopify_product_id.to_i,
      subscription_id: sub.subscription_id.to_i,
      product_title: sub.product_title,
      next_charge: sub.next_charge_scheduled_at.try{|time| time.strftime('%Y-%m-%d')},
      charge_date: sub.next_charge_scheduled_at.try{|time| time.strftime('%Y-%m-%d')},
      sizes: sub.sizes,
      prepaid: sub.prepaid?,
      prepaid_shipping_at: sub.shipping_at.try{|time| time.strftime('%Y-%m-%d')},
    }
  end

end


