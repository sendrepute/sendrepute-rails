# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

module SendRepute
  module Rails
    module CustomerApi
      class IntentConflict < StandardError
        attr_reader :status, :code, :record

        def initialize(status, code, message, record = nil)
          super(message)
          @status = status
          @code = code
          @record = record
        end
      end

      # Durable intent ledger for paid and billing operations.
      #
      # Identity: sha256 of credential fingerprint, operation, method, path and
      # the canonical request body. An intent is written as "pending" under an
      # atomic cross-worker lock BEFORE the outbound request, then moved to
      # "completed", "failed" (definitive refusal) or "ambiguous" (transport
      # error, timeout, 5xx). Pending, ambiguous and completed intents block an
      # identical request from any session, worker or restart until an operator
      # deliberately releases them. Subclasses implement atomic(key) and all.
      class IntentLedger
        KEY_RE = /\A[a-f0-9]{64}\z/

        def self.canonical_json(value)
          case value
          when Hash then "{#{value.keys.map(&:to_s).sort.map { |k| "#{JSON.generate(k)}:#{canonical_json(value.key?(k) ? value[k] : value[k.to_sym])}" }.join(',')}}"
          when Array then "[#{value.map { |v| canonical_json(v) }.join(',')}]"
          else JSON.generate(value)
          end
        end

        def self.key(fingerprint, prepared)
          body = prepared[:body].nil? ? "" : canonical_json(JSON.parse(prepared[:body]))
          Digest::SHA256.hexdigest(["sendrepute-intent-v1", fingerprint, prepared[:op]["id"], prepared[:method], prepared[:path], body].join("\n"))
        end

        def self.replay_field(op)
          return "recoveryId" if op["bodyFields"].include?("recoveryId")
          return "analysisId" if op["bodyFields"].include?("analysisId")

          nil
        end

        def self.new_replay_id(field)
          case field
          when "recoveryId" then SecureRandom.uuid
          when "analysisId" then "sr_#{SecureRandom.hex(16)}"
          end
        end

        def begin_intent(key, meta, now)
          check(key)
          atomic(key) do |rec|
            next [nil, { acquired: false, record: rec }] if rec && %w[pending ambiguous completed].include?(rec["state"])

            nxt = { "key" => key, "fingerprint" => meta[:fingerprint], "operationId" => meta[:operation_id], "state" => "pending",
                    "replayField" => meta[:replay_field], "replayId" => rec&.dig("replayId") || meta[:replay_id],
                    "createdAt" => rec ? rec["createdAt"] : now, "updatedAt" => now, "attempts" => (rec ? rec["attempts"].to_i : 0) + 1,
                    "httpStatus" => nil, "note" => nil }
            [nxt, { acquired: true, record: nxt }]
          end
        end

        def finish(key, state, http_status, now)
          check(key)
          atomic(key) do |rec|
            next [nil, rec] unless rec && rec["state"] == "pending"

            nxt = rec.merge("state" => state, "httpStatus" => http_status, "updatedAt" => now)
            [nxt, nxt]
          end
        end

        def release(key, fingerprint, reason, now)
          check(key)
          atomic(key) do |rec|
            raise IntentConflict.new(404, "INTENT_NOT_FOUND", "No intent with that key for this credential") unless rec && rec["fingerprint"] == fingerprint
            # Never time-based: a pending intent may belong to a stalled worker whose request is still in flight.
            if rec["state"] == "pending"
              raise IntentConflict.new(409, "INTENT_IN_PROGRESS", "This request may still be in flight. If its worker crashed, stop all workers and run offline recovery; it then becomes ambiguous and can be reconciled and released.", rec)
            end
            next [nil, rec] if %w[released failed].include?(rec["state"])

            # A completed charge must not reuse its replay id, otherwise upstream would replay the old result.
            nxt = rec.merge("state" => "released", "replayId" => rec["state"] == "completed" ? nil : rec["replayId"], "updatedAt" => now, "note" => reason.to_s[0, 200])
            [nxt, nxt]
          end
        end

        # OFFLINE ONLY (every worker stopped): leftover pending intents become ambiguous.
        def recover_pending_after_shutdown(all_workers_stopped:, now:)
          raise ArgumentError, "Stop every console worker first, then pass all_workers_stopped: true" unless all_workers_stopped == true

          all.select { |r| r["state"] == "pending" }.filter_map do |r|
            atomic(r["key"]) do |cur|
              next [nil, nil] unless cur && cur["state"] == "pending"

              [cur.merge("state" => "ambiguous", "updatedAt" => now, "note" => "recovered offline after all workers stopped"), cur["key"]]
            end
          end
        end

        def list(fingerprint)
          all.select { |r| r["fingerprint"] == fingerprint && r["state"] != "released" }.sort_by { |r| -r["updatedAt"].to_i }.first(200)
        end

        private

        def check(key)
          raise IntentConflict.new(400, "INVALID_PARAMETER", "intentKey is invalid") unless key.is_a?(String) && key.match?(KEY_RE)
        end
      end

      # Filesystem intent store. SINGLE HOST ONLY: File#flock is atomic across
      # Puma/Unicorn workers on one machine (and released if a worker dies) but
      # not across machines or on network filesystems. Construction fails unless
      # single_host: true is acknowledged and the directory is absolute, private
      # (0700) and owned by the Ruby process user.
      class FileIntentStore < IntentLedger
        def initialize(directory:, single_host: false)
          super()
          raise ApiError.new("configuration", "The filesystem intent store supports a single host only; set single_host: true to acknowledge") unless single_host == true
          raise ApiError.new("configuration", "Intent store directory must be an absolute path") unless directory.is_a?(String) && directory.start_with?("/")

          FileUtils.mkdir_p(directory, mode: 0o700)
          st = File.lstat(directory)
          raise ApiError.new("configuration", "Intent store directory must be a real directory") if st.symlink? || !st.directory?
          raise ApiError.new("configuration", "Intent store directory must not be group or world accessible (chmod 700)") unless (st.mode & 0o077).zero?
          raise ApiError.new("configuration", "Intent store directory must be owned by the server user") unless st.uid == Process.euid

          @dir = directory.chomp("/")
        end

        def atomic(key)
          File.open(File.join(@dir, "#{key}.lock"), File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            path = File.join(@dir, "#{key}.json")
            current = File.exist?(path) ? JSON.parse(File.read(path)) : nil
            nxt, result = yield(current)
            if nxt
              tmp = File.join(@dir, "#{key}.#{SecureRandom.hex(6)}.tmp")
              File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
                f.write(JSON.generate(nxt))
                f.flush
                f.fsync
              end
              File.rename(tmp, path)
            end
            result
          end
        rescue SystemCallError
          raise IntentConflict.new(503, "INTENT_STORE_UNAVAILABLE", "Intent store is unavailable; nothing was sent")
        end

        def all
          Dir.glob(File.join(@dir, "*.json")).filter_map do |f|
            next unless File.basename(f).match?(/\A[a-f0-9]{64}\.json\z/)

            JSON.parse(File.read(f))
          rescue JSON::ParserError
            nil
          end
        end
      end
    end
  end
end
