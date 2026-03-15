# frozen_string_literal: true

require 'stringio'
require 'zlib'

describe WPScan::Sitemap::Discovery do
  subject(:discovery) { described_class.new(target) }

  let(:target)   { WPScan::Target.new(url) }
  let(:url)      { 'https://example.com/' }
  let(:fixtures) { FIXTURES.join('sitemap') }

  before { allow(target).to receive(:sub_dir).and_return(false) }

  describe '#from_robots_txt' do
    it 'extracts sitemap URLs from robots.txt directives' do
      stub_request(:get, target.url('robots.txt')).to_return(body: <<~ROBOTS)
        User-agent: *
        Allow: /
        Sitemap: https://example.com/wp-sitemap.xml
        sitemap: https://example.com/sitemap_index.xml
      ROBOTS

      expect(discovery.from_robots_txt).to eq([
        'https://example.com/wp-sitemap.xml',
        'https://example.com/sitemap_index.xml'
      ])
    end
  end

  describe '#candidates' do
    it 'adds fallback endpoints after robots.txt discovered URLs' do
      stub_request(:get, target.url('robots.txt')).to_return(body: '')

      expect(discovery.candidates).to start_with('https://example.com/wp-sitemap.xml')
      expect(discovery.candidates).to include('https://example.com/sitemap.xml.gz')
    end
  end
end

describe WPScan::Sitemap::Parser do
  subject(:parser) { described_class.new }

  let(:fixtures) { FIXTURES.join('sitemap') }

  describe '#parse' do
    it 'accepts a valid urlset sitemap' do
      result = parser.parse(File.binread(fixtures.join('urlset.xml')))

      expect(result).not_to be_nil
      expect(parser.root_type(result)).to eq(:urlset)
    end

    it 'accepts a valid sitemapindex sitemap' do
      result = parser.parse(File.binread(fixtures.join('sitemapindex.xml')))

      expect(result).not_to be_nil
      expect(parser.root_type(result)).to eq(:sitemapindex)
    end

    it 'accepts XML with prefixed namespaces' do
      result = parser.parse(File.binread(fixtures.join('namespaced_urlset.xml')))

      expect(result).not_to be_nil
      expect(parser.root_type(result)).to eq(:urlset)
    end

    it 'accepts gzipped sitemap content' do
      gzipped_sitemap = StringIO.new.tap do |io|
        Zlib::GzipWriter.wrap(io) { |gzip| gzip.write(File.binread(fixtures.join('urlset.xml'))) }
      end.string.b

      result = parser.parse(gzipped_sitemap, source_url: 'https://example.com/sitemap.xml.gz')

      expect(result).not_to be_nil
      expect(parser.root_type(result)).to eq(:urlset)
    end

    it 'rejects HTML masquerading as XML sitemap content' do
      result = parser.parse(File.binread(fixtures.join('html_page.html')), source_url: 'https://example.com/sitemap.xml')

      expect(result).to be_nil
    end
  end
end

describe WPScan::Sitemap::VendorClassifier do
  subject(:classifier) { described_class.new }

  let(:fixtures) { FIXTURES.join('sitemap') }

  it 'classifies wordpress core sitemaps' do
    expect(classifier.classify(url: 'https://example.com/wp-sitemap.xml')).to eq(:wordpress_core)
  end

  it 'classifies yoast sitemaps' do
    xml = File.binread(fixtures.join('yoast_urlset.xml'))

    expect(classifier.classify(url: 'https://example.com/sitemap_index.xml', xml_body: xml)).to eq(:yoast)
  end

  it 'classifies jetpack sitemaps' do
    xml = File.binread(fixtures.join('jetpack_sitemap.xml'))

    expect(classifier.classify(url: 'https://example.com/sitemap.xml', xml_body: xml)).to eq(:jetpack)
  end

  it 'classifies unknown sitemap vendors' do
    expect(classifier.classify(url: 'https://example.com/custom.xml')).to eq(:unknown)
  end
end
