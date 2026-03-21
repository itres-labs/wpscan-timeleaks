# frozen_string_literal: true

require 'securerandom'

module WPScan
  module Finders
    module InterestingFindings
      # Opt-in predictive media finder based on passively observed media URLs.
      class PredictableMedia < CMSScanner::Finders::Finder
        MAX_SEEDS = 200
        MAX_CANDIDATES_PER_SEED = 8
        MAX_CANDIDATE_REQUESTS = 300
        MAX_BASELINE_REQUESTS = 2
        MAX_EXAMPLES = 10

        SENSITIVE_SUFFIXES = %w[draft borrador redacted private].freeze
        MEDIA_LIKE_EXT = /\.(?:jpe?g|png|gif|webp|svg|bmp|ico|tiff?|avif|mp4|mov|webm|mp3|wav|ogg|pdf)\z/i

        # @return [InterestingFinding, nil]
        def aggressive(_opts = {})
          return unless ParsedCli.predictable_media

          baseline = baseline_404
          return if baseline.nil?

          seeds = observed_media_seeds
          return if seeds.empty?

          predicted = verify_candidates(seeds, baseline)
          return if predicted.empty?

          Model::PredictableMedia.new(
            target.url,
            confidence: baseline[:soft_404] ? 65 : 75,
            found_by: DIRECT_ACCESS,
            interesting_entries: predicted.take(MAX_EXAMPLES),
            predicted_count: predicted.size
          )
        end

        private

        def baseline_404
          @baseline_requests ||= 0

          responses = []
          2.times do
            break if @baseline_requests >= MAX_BASELINE_REQUESTS

            @baseline_requests += 1
            res = Browser.get(target.url("wp-content/uploads/this-should-not-exist-#{SecureRandom.hex(6)}.jpg"))
            responses << res if res
          end

          return if responses.empty?

          html_baseline = responses.find { |res| html_response?(res) }

          {
            soft_404: responses.any? { |res| res.code == 200 && html_response?(res) },
            html_signature: html_signature(html_baseline),
            html_size: html_baseline&.body.to_s&.bytesize,
            html_code: html_baseline&.code
          }
        end

        def observed_media_seeds
          context = target.instance_variable_get(:@predictable_media_seed_context) || {}
          target_host = target.uri.host

          suspicious = Array(context[:suspicious_urls]).select { |url| media_url?(url) && same_host?(url, target_host) }
          discovered = Array(context[:discovered_urls]).select { |url| media_url?(url) && same_host?(url, target_host) }
          passive = passive_media_seeds

          (suspicious + discovered + passive).uniq.take(MAX_SEEDS)
        end

        def passive_media_seeds
          [target.homepage_res, target.error_404_res].compact.flat_map do |res|
            next [] unless html_response?(res)

            media_urls_from_html(res.body.to_s, base_url: res.effective_url)
          end
        end

        def media_urls_from_html(html, base_url:)
          doc = Nokogiri::HTML(html)
          urls = []

          urls.concat(attribute_urls(doc, 'img', %w[src data-src data-lazy-src data-original-src]))
          urls.concat(attribute_urls(doc, 'img', %w[srcset data-srcset], srcset: true))
          urls.concat(attribute_urls(doc, 'source', %w[srcset data-srcset], srcset: true))
          urls.concat(attribute_urls(doc, 'a', ['href']))

          urls.filter_map { |url| normalize_url(url, base_url: base_url) }
              .select { |url| media_url?(url) }
              .uniq
        end

        def verify_candidates(seeds, baseline)
          seen = {}
          found = []
          requests = 0

          seeds.each do |seed|
            candidates_for_seed(seed).each do |candidate|
              next if candidate == seed || seen[candidate]
              break if requests >= MAX_CANDIDATE_REQUESTS

              seen[candidate] = true
              requests += 1

              res = Browser.get(candidate)
              next unless valid_candidate_response?(res, baseline)

              found << candidate
            end

            break if requests >= MAX_CANDIDATE_REQUESTS
          end

          found.uniq
        end

        def candidates_for_seed(seed)
          uri = Addressable::URI.parse(seed)
          path = uri.path.to_s
          ext = File.extname(path)
          return [] if ext.empty?

          stem = path[0..-(ext.length + 1)]
          candidates = []

          stripped = strip_sensitive_suffix(stem)
          candidates << rebuild_url(uri, "#{stripped}#{ext}") if stripped

          numeric_neighbors(stem).each do |neighbor_stem|
            candidates << rebuild_url(uri, "#{neighbor_stem}#{ext}")
          end

          candidates.uniq.take(MAX_CANDIDATES_PER_SEED)
        rescue Addressable::URI::InvalidURIError
          []
        end

        def strip_sensitive_suffix(stem)
          return unless stem =~ /-(#{SENSITIVE_SUFFIXES.join('|')})\z/i

          stem.sub(/-(#{SENSITIVE_SUFFIXES.join('|')})\z/i, '')
        end

        def numeric_neighbors(stem)
          match = stem.match(/^(.*?)(\d+)([^\d]*)$/)
          return [] unless match

          prefix = match[1]
          number = match[2]
          suffix = match[3]
          width = number.length
          value = number.to_i

          [-2, -1, 1, 2].filter_map do |delta|
            next_value = value + delta
            next if next_value.negative?

            "#{prefix}#{next_value.to_s.rjust(width, '0')}#{suffix}"
          end
        end

        def rebuild_url(uri, new_path)
          updated = uri.dup
          updated.path = new_path
          updated.to_s
        end

        def valid_candidate_response?(response, baseline)
          return false unless response
          return false unless response.code == 200
          return false if html_like_baseline?(response, baseline)
          return false unless acceptable_non_html_content_type?(response)

          response.body.to_s.bytesize >= 32
        end

        def html_like_baseline?(response, baseline)
          return false unless html_response?(response)

          signature = html_signature(response)
          similar_size = baseline[:html_size] && (response.body.to_s.bytesize - baseline[:html_size]).abs < 64

          baseline[:soft_404] ||
            (baseline[:html_signature] && signature == baseline[:html_signature]) ||
            (baseline[:html_code] && response.code == baseline[:html_code] && similar_size)
        end

        def html_signature(response)
          return unless response

          body = response.body.to_s
          text = Nokogiri::HTML(body).xpath('//text()').map(&:text).join(' ').gsub(/\s+/, ' ').strip
          return if text.empty?

          text.downcase[0, 160]
        end

        def acceptable_non_html_content_type?(response)
          content_type = response.headers['Content-Type'].to_s.downcase.split(';').first

          return false if content_type.empty?
          return false if content_type.include?('html')

          content_type.start_with?('image/', 'video/', 'audio/') ||
            %w[application/pdf application/octet-stream].include?(content_type)
        end

        def attribute_urls(doc, selector, attributes, srcset: false)
          urls = []

          doc.css(selector).each do |node|
            attributes.each do |attribute|
              value = node[attribute].to_s.strip
              next if value.empty?

              if srcset
                urls.concat(value.split(',').map { |entry| entry.strip.split(/\s+/, 2).first })
              else
                urls << value
              end
            end
          end

          urls
        end

        def normalize_url(url, base_url:)
          return if url.start_with?('#', 'data:', 'javascript:')

          normalized = Addressable::URI.parse(base_url).join(url)
          return unless normalized.host == target.uri.host

          normalized.to_s
        rescue Addressable::URI::InvalidURIError
          nil
        end

        def media_url?(url)
          normalized = url.to_s.downcase.split('?').first

          normalized.include?('/wp-content/uploads/') || normalized.match?(MEDIA_LIKE_EXT)
        end

        def same_host?(url, host)
          Addressable::URI.parse(url).host == host
        rescue Addressable::URI::InvalidURIError
          false
        end

        def html_response?(response)
          content_type = response.headers['Content-Type'].to_s

          return true if content_type.match?(%r{\Atext/html\b}i)

          response.body.to_s.lstrip.match?(%r{\A<(?:!doctype\s+html|html)\b}i)
        end
      end
    end
  end
end
