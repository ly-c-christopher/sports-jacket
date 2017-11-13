ENV['RACK_ENV'] = 'test'

require_relative '../src/ellie_listener.rb'
require_relative '../src/logging.rb'
require 'test/unit'
require 'rack/test'

class ListenerTest < Test::Unit::TestCase
  include Rack::Test::Methods
  include Logging

  def app
    EllieListener
  end

  def test_it_says_hello_world
    get '/hello'
    assert last_response.ok?
    assert !last_response.body.empty?
  end

  def test_it_responds_to_subscriptions_get
    get '/subscriptions'
    assert last_response.ok?
  end

  def test_it_updates_a_subscription
    sub = Subscription.last
    put "/subscriptions/#{sub.subscription_id}", shopify_id: 'silly value'
    assert last_response.ok?
    json = JSON.parse(last_response.body)
    # check that we returned a 'preview' of what the updated object will look
    # like after sent to rechrge successfully
    assert_equal json['shopify_id'], 'silly_value'
    # check that unsent values remain the same
    assert_equal json['price'], sub.price, 'updated price value did not match expected value'
    assert_equal json['properties'], sub.as_recharge.properties, 'updated properties did not match expected value'
  end

  def test_it_retrieves_a_subscription
    f = File.open("#{File.dirname __FILE__}/../docs/subscription_example.json")
    example_json = JSON.parse f.read
    sub = Subscription.last
    get "/subscriptions/#{sub.subscription_id}"
    assert last_response.ok?
    json = JSON.parse(last_response.body)
    assert_equal example_json['subscription'].keys.sort, json.keys.sort, 'output did not match Recharge API'
  end

  def test_it_retrieves_a_customer
    f = File.open("#{File.dirname __FILE__}/../docs/customer_example.json")
    example_json = JSON.parse f.read
    customer = Customer.last
    get "/customers/#{customer.customer_id}"
    assert last_response.ok?
    json = JSON.parse(last_response.body)
    assert_equal example_json['customer'].keys.sort, json.keys.sort, 'output did not match recharge API'

  def test_customer_index_returns_max_results
    get '/customers'
    assert last_response.ok?
    customer_list = JSON.parse last_response.body
    assert customer_list.length <= 250
  end

  def test_customers_match_recharge_api
    customer = Customer.last
    file = File.open "#{File.dirname __FILE__}/../docs/customer_example.json", 'r'
    example_json = file.read
    logger.debug example_json
    example = JSON.parse example_json
    get "/customers/#{customer.customer_id}"
    logger.debug last_response.body
    response = JSON.parse last_response.body
    logger.debug response
    assert example['customer'].keys == response.keys
  end

end
