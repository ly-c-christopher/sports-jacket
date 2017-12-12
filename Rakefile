require 'dotenv'
Dotenv.load
require 'redis'
require 'resque'
Resque.redis = Redis.new(url: ENV['REDIS_URL'])
require 'sinatra/activerecord'
require 'sinatra/activerecord/rake'
require 'resque/tasks'

require_relative 'models/all'
Dir['worker/**/*.rb'].each do |file|
  require_relative file
end

Resque.logger =
  if ENV['production']
    Logger.new STDOUT, level: Logger::WARNING
  else
    Logger.new STDOUT, level: Logger::INFO
  end

desc 'do full or partial pull of customers and add to DB'
task :customer_pull, [:args] do |t, args|
  DetermineInfo::InfoGetter.new.handle_customers(*args)
end

desc 'do full or partial pull of charge table and associated tables and add to DB'
task :charge_pull, [:args] do |t, args|
  DetermineInfo::InfoGetter.new.handle_charges(*args)
end

desc 'do full or partial pull of order table and associated tables and add to DB'
task :order_pull, [:args] do |t, args|
  DetermineInfo::InfoGetter.new.handle_orders(*args)
end

desc 'do full or partial pull of subscription table and associated tables and add to DB'
task :subscription_pull, [:args] do |t, args|
  DetermineInfo::InfoGetter.new.handle_subscriptions(*args)
end

desc 'run all tests'
task :test do
  require 'rake/testtask'
  Rake::TestTask.new do |t|
    t.pattern = 'test/*_test.rb'
  end
end

desc 'set up subscriptions_updated table, delete old data and reset id sequence'
task :setup_subscriptions_updated do |t|
  DetermineInfo::InfoGetter.new.setup_subscription_update_table

end


desc 'update subscription properties sku, title, product_id, variant_id'
task :update_subscription_product do |t|
  DetermineInfo::InfoGetter.new.update_subscription_product

end


desc 'load current product key-value pairs into current_products table for updating subscriptions'
task :load_current_product do |t|
  DetermineInfo::InfoGetter.new.load_current_products
end


desc 'load update_products table with new data for updating the subscriptions each month'
task :load_update_products do |t|
  DetermineInfo::InfoGetter.new.load_update_products
end
