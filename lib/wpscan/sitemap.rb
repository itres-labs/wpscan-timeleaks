# frozen_string_literal: true

require 'stringio'
require 'zlib'

module WPScan
  module Sitemap
    # Sitemap URL discovery from robots.txt and common fallback endpoints
    class Discovery
      FALLBACK_PATHS = %w[
        wp-sitemap.xml
        sitemap_index.xml
        sitemap.xml
        news-sitemap.xml
        wp-sitemap.xml.gz
        sitemap_index.xml.gz
        sitemap.xml.gz
        news-sitemap.xml.gz
      ].freeze

      attr_reader :target

      def initialize(target)
        @target = target
      end

      # @return [Array<String>]
      def from_robots_txt
        body = Browser.get(target.url('robots.txt')).body.to_s

        body.scan(/^\s*sitemap:\s*(\S+)/i).flatten.map(&:strip).uniq
      end

      # @return [Array<String>]
      def fallback_urls
        FALLBACK_PATHS.map { |path| target.url(path) }
      end

      # @return [Array<String>]
      def candidates
        (from_robots_txt + fallback_urls).uniq
      end
    end

    # Validates and parses sitemap XML content
    class Parser
      VALID_ROOTS = %w[sitemapindex urlset].freeze

      # @param [String] body
      # @param [String,nil] source_url
      #
      # @return [Nokogiri::XML::Document,nil]
      def parse(body, source_url: nil, headers: nil)
        xml = Nokogiri::XML(parsed_body(body, source_url: source_url, headers: headers)) { |cfg| cfg.strict.nonet }

        return unless xml.errors.empty?
        return if xml.root.nil?
        return unless VALID_ROOTS.include?(xml.root.name.split(':').last)

        xml
      rescue Nokogiri::XML::SyntaxError, Zlib::GzipFile::Error
        nil
      end

      # @param [Nokogiri::XML::Document] xml
      #
      # @return [Symbol,nil]
      def root_type(xml)
        return if xml&.root.nil?

        xml.root.name.split(':').last.to_sym
      end

      private

      def parsed_body(body, source_url: nil, headers: nil)
        xml_like = maybe_unzip(body.to_s, headers: headers)

        raise Nokogiri::XML::SyntaxError, 'HTML detected instead of XML' if html_response?(xml_like)

        xml_like
      end

      def maybe_unzip(body, headers: nil)
        return body unless gzip?(body, headers: headers)

        Zlib::GzipReader.new(StringIO.new(body)).read
      end

      def gzip?(body, headers: nil)
        return true if body.start_with?("\x1F\x8B".b)

        header_gzip?(headers)
      end

      def header_gzip?(headers)
        return false unless headers

        content_encoding = header_value(headers, 'Content-Encoding')
        content_type = header_value(headers, 'Content-Type')

        content_encoding.to_s.downcase.include?('gzip') ||
          content_type.to_s.downcase.split(';').first == 'application/x-gzip'
      end

      def header_value(headers, key)
        headers[key] || headers[key.downcase] || headers[key.upcase]
      end

      def html_response?(body)
        body.lstrip.match?(%r{\A<(?:!doctype\s+html|html)\b}i)
      end
    end

    # Classifies sitemap vendor using URL and XML content signals
    class VendorClassifier
      # @param [String] url
      # @param [String,nil] xml_body
      #
      # @return [Symbol]
      def classify(url:, xml_body: nil)
        normalized_path = normalized_path(url)
        xml_body = xml_body.to_s

        return :yoast if yoast_signal?(normalized_path, xml_body)
        return :jetpack if jetpack_signal?(normalized_path, xml_body)
        return :wordpress_core if wordpress_core_signal?(normalized_path, xml_body)

        :unknown
      end

      private

      def normalized_path(url)
        Addressable::URI.parse(url.to_s).path.to_s.downcase
      rescue Addressable::URI::InvalidURIError
        ''
      end

      def yoast_signal?(path, body)
        path.match?(%r{/(?:[^/]+-)?(?:post|page|category|post_tag|author)-sitemap\d*\.xml\z}) ||
          body.match?(%r{/wp-content/plugins/wordpress-seo/}i) ||
          body.match?(%r{https?://wordpress\.org/plugins/wordpress-seo/}i) ||
          body.match?(%r{https?://yoast\.com/}i)
      end

      def jetpack_signal?(path, body)
        path.include?('-image-sitemap') ||
          body.match?(%r{/wp-content/plugins/jetpack/}i) ||
          body.match?(%r{xmlns:(?:jetpack|jp)\s*=\s*["']https?://jetpack\.com/}i)
      end

      def wordpress_core_signal?(path, body)
        path.include?('/wp-sitemap') || body.include?('wp-sitemap.xsl')
      end
    end
  end
end
