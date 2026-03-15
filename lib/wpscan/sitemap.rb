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
      def parse(body, source_url: nil)
        xml = Nokogiri::XML(parsed_body(body, source_url: source_url)) { |cfg| cfg.strict.nonet }

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

      def parsed_body(body, source_url: nil)
        xml_like = maybe_unzip(body.to_s, source_url: source_url)

        raise Nokogiri::XML::SyntaxError, 'HTML detected instead of XML' if html_response?(xml_like)

        xml_like
      end

      def maybe_unzip(body, source_url: nil)
        return body unless gzip?(body, source_url: source_url)

        Zlib::GzipReader.new(StringIO.new(body)).read
      end

      def gzip?(body, source_url: nil)
        body.start_with?("\x1F\x8B".b) || source_url.to_s.end_with?('.gz')
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
        haystack = [url.to_s.downcase, xml_body.to_s.downcase].join("\n")

        return :yoast if haystack.include?('wordpress-seo') || haystack.include?('yoast')
        return :jetpack if haystack.include?('jetpack')
        return :wordpress_core if haystack.include?('/wp-sitemap') || haystack.include?('wp-sitemap.xsl')

        :unknown
      end
    end
  end
end
