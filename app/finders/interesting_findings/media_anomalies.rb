# frozen_string_literal: true

module WPScan
  module Finders
    module InterestingFindings
      # Sitemap-based media anomaly finder
      class MediaAnomalies < CMSScanner::Finders::Finder
        MAX_EXTRA_REQUESTS = 80
        MAX_SITEMAP_URLS = 500
        MAX_SAMPLED_PAGES = 50
        MAX_VERIFICATIONS = 20
        MAX_EXAMPLES = 10
        MAX_SITEMAP_DOCS = 10

        MEDIA_LIKE_EXT = /\.(?:jpe?g|png|gif|webp|svg|bmp|ico|tiff?|avif|mp4|mov|webm|mp3|wav|ogg|pdf)\z/i

        # @return [InterestingFinding, nil]
        def aggressive(_opts = {})
          reset_counters

          sitemap_urls, page_urls, vendors, declared_media_by_page = collect_sitemap_urls

          return if sitemap_urls.empty? || page_urls.empty?

          observed_media, observed_media_by_page, sampled_pages = sampled_rendered_media(page_urls)
          anomalies = anomaly_candidates(
            sitemap_urls: sitemap_urls,
            observed_media: observed_media,
            declared_media_by_page: declared_media_by_page,
            observed_media_by_page: observed_media_by_page,
            sampled_pages: sampled_pages
          )

          cache_predictable_media_seeds(anomalies, observed_media, sitemap_urls)

          verified = verify_media_urls(anomalies)

          return if verified.empty?

          jetpack_context = vendors.include?(:jetpack)

          Model::MediaAnomalies.new(
            target.url,
            confidence: jetpack_context ? 80 : 65,
            found_by: DIRECT_ACCESS,
            interesting_entries: verified.take(MAX_EXAMPLES),
            anomaly_count: verified.size,
            jetpack_context: jetpack_context
          )
        end

        private

        def reset_counters
          @request_count = 0
          @sitemap_doc_count = 0
        end

        # @return [Array<Array<String>, Array<String>, Array<Symbol>, Hash{String => Array<String>}>]
        def collect_sitemap_urls
          discovery = Sitemap::Discovery.new(target)
          parser = Sitemap::Parser.new
          classifier = Sitemap::VendorClassifier.new

          sitemap_media = []
          public_pages = []
          vendors = []
          declared_media_by_page = Hash.new { |hash, key| hash[key] = [] }
          queue = discovery.candidates.dup
          seen = {}

          until queue.empty? || @sitemap_doc_count >= MAX_SITEMAP_DOCS || request_budget_reached?
            sitemap_url = queue.shift
            next if seen[sitemap_url]

            seen[sitemap_url] = true

            response = budget_get(sitemap_url)
            next unless response && response.code == 200

            xml = parser.parse(response.body, source_url: response.effective_url, headers: response.headers)
            next unless xml

            @sitemap_doc_count += 1
            vendors << classifier.classify(url: response.effective_url, xml_body: response.body)

            case parser.root_type(xml)
            when :sitemapindex
              queue.concat(sitemap_children(xml))
            when :urlset
              sitemap_urls(xml).each do |entry|
                url = entry[:loc]
                image_urls = entry[:image_locs].select { |image_url| media_url?(image_url) }

                if image_urls.any?
                  sitemap_media.concat(image_urls)

                  next unless url && !media_url?(url)

                  public_pages << url
                  declared_media_by_page[url].concat(image_urls)
                elsif media_url?(url)
                  sitemap_media << url
                else
                  public_pages << url
                end
              end
            end

            break if sitemap_media.size >= MAX_SITEMAP_URLS
          end

          [
            sitemap_media.uniq.take(MAX_SITEMAP_URLS),
            public_pages.uniq.take(MAX_SAMPLED_PAGES),
            vendors.uniq,
            declared_media_by_page.transform_values { |urls| urls.uniq }
          ]
        end

        def sampled_rendered_media(page_urls)
          observed = []
          by_page = {}
          sampled_pages = []

          page_urls.each do |page_url|
            break if request_budget_reached?

            response = budget_get(page_url)
            next unless response && response.code == 200
            next unless html_response?(response)

            media = media_urls_from_html(response.body.to_s, base_url: response.effective_url)

            observed.concat(media)
            by_page[page_url] = media
            sampled_pages << page_url

            effective_url = response.effective_url.to_s
            by_page[effective_url] = media if !effective_url.empty? && effective_url != page_url
          end

          [observed.uniq, by_page.transform_values(&:uniq), sampled_pages.uniq]
        end

        def anomaly_candidates(sitemap_urls:, observed_media:, declared_media_by_page:, observed_media_by_page:, sampled_pages:)
          canonical_observed_media = observed_media.filter_map { |url| canonical_media_identifier(url) }.uniq
          canonical_sitemap_urls = sitemap_urls.filter_map { |url| canonical_media_identifier(url) }.uniq

          sampled_declared = declared_media_by_page.select { |page_url, _| sampled_pages.include?(page_url) }
          mapped_urls = declared_media_by_page.values.flatten.uniq
          mapped_anomalies = sampled_declared.flat_map do |page_url, declared_urls|
            observed_for_page = observed_media_by_page.fetch(page_url, [])
            observed_ids = observed_for_page.filter_map { |url| canonical_media_identifier(url) }.uniq

            declared_urls.reject do |declared_url|
              canonical = canonical_media_identifier(declared_url)
              canonical && observed_ids.include?(canonical)
            end
          end

          canonical_mapped_urls = mapped_urls.filter_map { |url| canonical_media_identifier(url) }.uniq
          unmapped_anomalies = sitemap_urls.reject do |url|
            canonical = canonical_media_identifier(url)
            canonical && (canonical_mapped_urls.include?(canonical) || canonical_observed_media.include?(canonical))
          end

          (mapped_anomalies + unmapped_anomalies).uniq.select do |url|
            canonical = canonical_media_identifier(url)
            canonical && canonical_sitemap_urls.include?(canonical)
          end
        end

        def verify_media_urls(urls)
          verified = []

          urls.take(MAX_VERIFICATIONS).each do |url|
            break if request_budget_reached?

            res = budget_get(url)
            next unless res && res.code == 200
            next if html_response?(res)
            next unless acceptable_media_content_type?(res)

            verified << url
          end

          verified.uniq
        end

        def cache_predictable_media_seeds(anomalies, observed_media, sitemap_urls)
          target.instance_variable_set(
            :@predictable_media_seed_context,
            {
              suspicious_urls: anomalies.uniq,
              discovered_urls: (observed_media + sitemap_urls).uniq
            }
          )
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

          Addressable::URI.parse(base_url).join(url).to_s
        rescue Addressable::URI::InvalidURIError
          nil
        end

        def sitemap_children(xml)
          xml.xpath('//*[local-name()="sitemap"]/*[local-name()="loc"]').map(&:text).map(&:strip)
        end

        def sitemap_urls(xml)
          xml.xpath('//*[local-name()="url"]').filter_map do |url_node|
            loc = url_node.at_xpath('./*[local-name()="loc"]')&.text&.strip
            next if loc.nil? || loc.empty?

            image_locs = url_node.xpath('.//*[local-name()="image"]/*[local-name()="loc"]').map(&:text).map(&:strip)

            { loc: loc, image_locs: image_locs }
          end
        end

        def media_url?(url)
          normalized = url.to_s.downcase.split('?').first

          normalized.include?('/wp-content/uploads/') || normalized.match?(MEDIA_LIKE_EXT)
        end

        def canonical_media_identifier(url)
          uri = Addressable::URI.parse(url.to_s)
          path = uri.path.to_s
          return if path.empty?

          normalized_path = path.downcase.gsub(%r{/+}, '/')
          upload_index = normalized_path.index('/wp-content/uploads/')

          if upload_index
            normalized_path[upload_index..]
          else
            normalized_path
          end
        rescue Addressable::URI::InvalidURIError
          nil
        end

        def acceptable_media_content_type?(response)
          content_type = response.headers['Content-Type'].to_s.downcase.split(';').first

          return false if content_type.empty?

          content_type.start_with?('image/', 'video/', 'audio/') ||
            %w[application/pdf application/octet-stream].include?(content_type)
        end

        def html_response?(response)
          content_type = response.headers['Content-Type'].to_s

          return true if content_type.match?(%r{\Atext/html\b}i)

          response.body.to_s.lstrip.match?(%r{\A<(?:!doctype\s+html|html)\b}i)
        end

        def request_budget_reached?
          @request_count >= MAX_EXTRA_REQUESTS
        end

        def budget_get(url)
          return if request_budget_reached?

          @request_count += 1
          Browser.get(url)
        end
      end
    end
  end
end
