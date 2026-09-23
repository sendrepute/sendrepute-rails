# frozen_string_literal: true

module SendRepute
  module Rails
    class Message
      MAX_BODY_BYTES = 524_288
      SUPPORTED_TYPES = %w[text/plain text/html].freeze
      AMBIGUOUS_TRANSFER_ENCODING = /content-transfer-encoding\s*:\s*base64|=(?:\r?\n|[0-9a-f]{2})/i
      GLOBAL_BASE64 = /\A[A-Za-z0-9+\/=\r\n]+\z/

      def self.payload(mail)
        raise UnsupportedMessageError, "multipart messages are not supported" if mail.multipart?

        content_type = mail.mime_type || "text/plain"
        unless SUPPORTED_TYPES.include?(content_type.downcase)
          raise UnsupportedMessageError, "unsupported displayed content type: #{content_type}"
        end

        from_field = mail[:from]
        sender = from_field && Array(from_field.display_names).first
        raise UnsupportedMessageError, "sender display name is required" if sender.nil? || sender.strip.empty?
        raise UnsupportedMessageError, "sender display name exceeds 320 characters" if sender.length > 320

        subject = mail.subject.to_s
        raise UnsupportedMessageError, "subject is required" if subject.empty?
        raise UnsupportedMessageError, "subject exceeds 998 characters" if subject.length > 998

        body = mail.body.decoded
        body = body.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        raise UnsupportedMessageError, "body is required" if body.empty?
        raise UnsupportedMessageError, "decoded body exceeds 524288 characters" if body.length > MAX_BODY_BYTES
        raise UnsupportedMessageError, "decoded body exceeds 524288 bytes" if body.bytesize > MAX_BODY_BYTES
        reject_backend_ambiguity!(body)

        { sender: sender, subject: subject, body: body }
      rescue Mail::Field::ParseError, Mail::UnknownEncodingType => e
        raise UnsupportedMessageError, "message decoding failed: #{e.message}"
      end

      def self.reject_backend_ambiguity!(body)
        if body.include?("{") || body.include?("}")
          raise UnsupportedMessageError, "body contains CSS-brace normalization ambiguity"
        end
        if body.match?(AMBIGUOUS_TRANSFER_ENCODING)
          raise UnsupportedMessageError, "body contains transfer-decoding ambiguity"
        end

        trimmed = body.strip
        global_base64 = trimmed.length >= 80 &&
                        !trimmed.match?(/\s{2,}/) &&
                        trimmed.match?(GLOBAL_BASE64) &&
                        trimmed.gsub(/\s+/, "").length.modulo(4).zero?
        if global_base64
          raise UnsupportedMessageError, "body contains global base64 normalization ambiguity"
        end
      end
      private_class_method :reject_backend_ambiguity!
    end
  end
end
