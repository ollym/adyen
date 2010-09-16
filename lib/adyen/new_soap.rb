require "net/https"

module Adyen
  module SOAP
    # from http://curl.haxx.se/ca/cacert.pem
    CACERT = File.expand_path('../../../support/cacert.pem', __FILE__)

    class << self
      # Username for the HTTP Basic Authentication that Adyen uses. Your username
      # should be something like +ws@Company.MyAccount+
      # @return [String]
      attr_accessor :username

      # Password for the HTTP Basic Authentication that Adyen uses. You can choose
      # your password yourself in the user management tool of the merchant area.
      # @return [String] 
      attr_accessor :password
    end

    class XMLQuerier
      NS = {
        'payment'   => 'http://payment.services.adyen.com',
        'recurring' => 'http://recurring.services.adyen.com',
        'common'    => 'http://common.services.adyen.com'
      }

      def initialize(data)
        @node = data.is_a?(String) ? Nokogiri::XML::Document.parse(data) : data
      end

      def xpath(query)
        result = self.class.new(@node.xpath(query, NS))
        block_given? ? yield(result) : result
      end

      def text(query)
        xpath("#{query}/text()").to_s
      end

      def children
        @node.children
      end

      def empty?
        @node.empty?
      end

      def to_s
        @node.to_s
      end

      def map(&block)
        @node.map { |n| self.class.new(n) }.map(&block)
      end
    end

    class NewBase
      def self.endpoint
        @endpoint ||= URI.parse(const_get('ENDPOINT_URI') % Adyen.environment)
      end

      attr_reader :params

      def initialize(params = {})
        @params = params
      end

      def call_webservice_action(action, data)
        endpoint = self.class.endpoint

        post = Net::HTTP::Post.new(endpoint.path, 'Accept' => 'text/xml', 'Content-Type' => 'text/xml; charset=utf-8', 'SOAPAction' => action)
        post.basic_auth(Adyen::SOAP.username, Adyen::SOAP.password)
        post.body = data

        request = Net::HTTP.new(endpoint.host, endpoint.port)
        request.use_ssl = true
        request.ca_file = CACERT
        request.verify_mode = OpenSSL::SSL::VERIFY_PEER

        request.start do |http|
          response = http.request(post)
          #p response
          XMLQuerier.new(response.body)
        end
      end
    end

    class NewPaymentService < NewBase
      LAYOUT = <<EOS
<?xml version="1.0"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <soap:Body>
    <ns1:authorise xmlns:ns1="http://payment.services.adyen.com">
      <ns1:paymentRequest>
        <merchantAccount xmlns="http://payment.services.adyen.com">%s</merchantAccount>
        <reference xmlns="http://payment.services.adyen.com">%s</reference>
%s
      </ns1:paymentRequest>
    </ns1:authorise>
  </soap:Body>
</soap:Envelope>
EOS

      AMOUNT_PARTIAL = <<EOS
        <amount xmlns="http://payment.services.adyen.com">
          <currency xmlns="http://common.services.adyen.com">%s</currency>
          <value xmlns="http://common.services.adyen.com">%s</value>
        </amount>
EOS

      CARD_PARTIAL = <<EOS
        <card xmlns="http://payment.services.adyen.com">
          <holderName>%s</holderName>
          <number>%s</number>
          <cvc>%s</cvc>
          <expiryYear>%s</expiryYear>
          <expiryMonth>%02d</expiryMonth>
        </card>
EOS

      RECURRING_PARTIAL = <<EOS
        <recurring xmlns="http://recurring.services.adyen.com">
          <contract xmlns="http://payment.services.adyen.com">RECURRING</contract>
        </recurring>
EOS

      SHOPPER_PARTIALS = {
        :reference => '        <shopperReference xmlns="http://payment.services.adyen.com">%s</shopperReference>',
        :email     => '        <shopperEmail xmlns="http://payment.services.adyen.com">%s</shopperEmail>',
        :ip        => '        <shopperIP xmlns="http://payment.services.adyen.com">%s</shopperIP>',
      }

      ENDPOINT_URI = 'https://pal-%s.adyen.com/pal/servlet/soap/Payment'

      def amount_partial
        AMOUNT_PARTIAL % @params[:amount].values_at(:currency, :value)
      end

      def card_partial
        card  = @params[:card].values_at(:holder_name, :number, :cvc, :expiry_year)
        card << @params[:card][:expiry_month].to_i
        CARD_PARTIAL % card
      end

      def shopper_partial
        @params[:shopper].map { |k, v| SHOPPER_PARTIALS[k] % v }.join("\n")
      end

      def recurring_partial
        RECURRING_PARTIAL
      end

      def authorise_payment_request_body
        body = ''
        body << amount_partial
        body << card_partial
        body << recurring_partial if @params[:recurring]
        body << shopper_partial   if @params[:shopper]
        LAYOUT % [@params[:merchant_account], @params[:reference], body]
      end

      # TODO: validate necessary params
      def authorise_payment
        response = call_webservice_action('authorise', authorise_payment_request_body)
        response.xpath('//payment:authoriseResponse/payment:paymentResult') do |result|
          {
            :psp_reference  => result.text('./payment:pspReference'),
            :result_code    => result.text('./payment:resultCode'),
            :auth_code      => result.text('./payment:authCode'),
            :refusal_reason => result.text('./payment:refusalReason')
          }
        end
      end
    end

    class NewRecurringService < NewBase
      ENDPOINT_URI = 'https://pal-%s.adyen.com/pal/servlet/soap/Recurring'

      LAYOUT = <<EOS
<?xml version="1.0"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <soap:Body>
    <ns1:listRecurringDetails xmlns:ns1="http://recurring.services.adyen.com">
      <ns1:request>
        <ns1:recurring>
          <ns1:contract>RECURRING</ns1:contract>
        </ns1:recurring>
        <ns1:merchantAccount>%s</ns1:merchantAccount>
        <ns1:shopperReference>%s</ns1:shopperReference>
      </ns1:request>
    </ns1:listRecurringDetails>
  </soap:Body>
</soap:Envelope>
EOS

      def list_request_body
        LAYOUT % [@params[:merchant_account], @params[:shopper][:reference]]
      end

      def list
        response = call_webservice_action('listRecurringDetails', list_request_body)
        response.xpath('//recurring:listRecurringDetailsResponse/recurring:result') do |result|
          {
            :creation_date            => DateTime.parse(result.text('./recurring:creationDate')),
            :details                  => result.xpath('.//recurring:RecurringDetail').map { |node| parse_recurring_detail(node) },
            :last_known_shopper_email => result.text('./recurring:lastKnownShopperEmail'),
            :shopper_reference        => result.text('./recurring:shopperReference')
          }
        end
      end

      # @todo add support for elv
      def parse_recurring_detail(node)
        result = if node.xpath('./recurring:bank').children.empty?
          parse_card_details(node)
        else
          parse_bank_details(node)
        end

        result.merge({
          :recurring_detail_reference => node.text('./recurring:recurringDetailReference'),
          :variant                    => node.text('./recurring:variant'),
          :creation_date              => DateTime.parse(node.text('./recurring:creationDate'))
        })
      end

      def parse_card_details(node)
        node.xpath('./recurring:card') do |card|
          {
            :card => {
              :expiry_date => Date.new(card.text('./payment:expiryYear').to_i, card.text('./payment:expiryMonth').to_i, -1),
              :holder_name => card.text('./payment:holderName'),
              :number      => card.text('./payment:number')
            }
          }
        end
      end

      def parse_bank_details(node)
        node.xpath('./recurring:bank') do |bank|
          {
            :bank => {
              :bank_account_number => bank.text('./payment:bankAccountNumber'),
              :bank_location_id    => bank.text('./payment:bankLocationId'),
              :bank_name           => bank.text('./payment:bankName'),
              :bic                 => bank.text('./payment:bic'),
              :country_code        => bank.text('./payment:countryCode'),
              :iban                => bank.text('./payment:iban'),
              :owner_name          => bank.text('./payment:ownerName')
            }
          }
        end
      end
    end
  end
end
