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

          declared_by_parent, standalone_media, page_urls, vendors = collect_sitemap_data

          sample_pages = (declared_by_parent.keys + page_urls).uniq.take(MAX_SAMPLED_PAGES)
          return if sample_pages.empty?

          rendered_by_page, rendered_global = sampled_rendered_media(sample_pages)
          anomalies = anomalies_from(declared_by_parent, standalone_media, rendered_by_page, rendered_global)
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

        # @return [Array<Hash<String, Array<String>>, Array<String>, Array<String>, Array<Symbol>>]
        def collect_sitemap_data
          discovery = Sitemap::Discovery.new(target)
          parser = Sitemap::Parser.new
          classifier = Sitemap::VendorClassifier.new

          declared_by_parent = Hash.new { |h, k| h[k] = [] }
          standalone_media = []
          page_urls = []
          vendors = []

          queue = discovery.candidates.dup
          seen = {}

          until queue.empty? || @sitemap_doc_count >= MAX_SITEMAP_DOCS || request_budget_reached?
            sitemap_url = queue.shift
            next if seen[sitemap_url]

            seen[sitemap_url] = true

            response = budget_get(sitemap_url)
            next unless response && response.code == 200

            xml = parser.parse(response.body, source_url: response.effective_url)
            next unless xml

            @sitemap_doc_count += 1
            vendors << classifier.classify(url: response.effective_url, xml_body: response.body)

            case parser.root_type(xml)
            when :sitemapindex
              queue.concat(sitemap_children(xml))
            when :urlset
              process_urlset(xml, declared_by_parent, standalone_media, page_urls)
            end

            break if total_media_count(declared_by_parent, standalone_media) >= MAX_SITEMAP_URLS
          end

          [normalize_declared(declared_by_parent), standalone_media.uniq.take(MAX_SITEMAP_URLS), page_urls.uniq, vendors.uniq]
        end

        def process_urlset(xml, declared_by_parent, standalone_media, page_urls)
          xml.xpath('//*[local-name()="url"]').each do |url_node|
            parent = url_node.xpath('./*[local-name()="loc"]').first&.text.to_s.strip
            next if parent.empty?

            image_locs = url_node.xpath('.//*[local-name()="image"]/*[local-name()="loc"]')
                                 .map(&:text)
                                 .map(&:strip)
                                 .reject(&:empty?)

            if image_locs.empty?
              if media_url?(parent)
                standalone_media << parent
              else
                page_urls << parent
              end
              next
            end

            declared_by_parent[parent].concat(image_locs.select { |url| media_url?(url) })
          end
        end

        def normalize_declared(declared_by_parent)
          normalized = {}

          declared_by_parent.each do |parent, urls|
            next if urls.empty?

            normalized[parent] = urls.uniq.take(MAX_SITEMAP_URLS)
          end

          normalized
        end

        def total_media_count(declared_by_parent, standalone_media)
          declared_by_parent.values.flatten.size + standalone_media.size
        end

        # @return [Array<Hash<String, Array<String>>, Array<String>>]
        def sampled_rendered_media(page_urls)
          rendered_by_page = {}
          rendered_global = []

          page_urls.each do |page_url|
            break if request_budget_reached?

            response = budget_get(page_url)
            next unless response && response.code == 200
            next unless html_response?(response)

            urls = media_urls_from_html(response.body.to_s, base_url: response.effective_url)
            rendered_by_page[page_url] = urls
            rendered_global.concat(urls)
          end

          [rendered_by_page, rendered_global.uniq]
        end

        def anomalies_from(declared_by_parent, standalone_media, rendered_by_page, rendered_global)
          anomalies = []

          declared_by_parent.each do |parent, media_urls|
            observed_for_parent = rendered_by_page[parent] || []
            anomalies.concat(media_urls - observed_for_parent)
          end

          anomalies.concat(standalone_media - rendered_global)
          anomalies.uniq
        end

        def verify_media_urls(urls)
          verified = []

          urls.take(MAX_VERIFICATIONS).each do |url|
            break if request_budget_reached?

            res = budget_get(url)
            next unless res && res.code == 200
            next if html_response?(res)

            verified << url
          end

          verified.uniq
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

        def media_url?(url)
          normalized = url.to_s.downcase.split('?').first

          normalized.include?('/wp-content/uploads/') || normalized.match?(MEDIA_LIKE_EXT)
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
