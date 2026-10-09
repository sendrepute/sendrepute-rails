# frozen_string_literal: true

require "minitest/autorun"
require "action_mailer"
require_relative "../lib/sendrepute-rails"

ActionMailer::Base.delivery_method = :test
ActionMailer::Base.perform_deliveries = true
ActionMailer::Base.deliveries.clear
