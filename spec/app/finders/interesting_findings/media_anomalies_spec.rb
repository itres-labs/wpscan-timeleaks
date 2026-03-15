# frozen_string_literal: true

describe WPScan::Finders::InterestingFindings::MediaAnomalies do
  subject(:finder) { described_class.new(target) }

  let(:target) { WPScan::Target.new(url) }
  let(:url) { 'http://ex.lo/' }
  let(:sitemap_fixtures) { FIXTURES.join('sitemap') }

  let(:sitemap_index) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <sitemap><loc>http://ex.lo/post-sitemap.xml</loc></sitemap>
        <sitemap><loc>http://ex.lo/media-sitemap.xml</loc></sitemap>
      </sitemapindex>
    XML
  end

  let(:post_sitemap) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>http://ex.lo/post-1/</loc></url>
      </urlset>
    XML
  end

  let(:media_sitemap) do
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>http://ex.lo/wp-content/uploads/2024/10/present.jpg</loc></url>
        <url><loc>http://ex.lo/wp-content/uploads/2024/10/orphan.jpg</loc></url>
      </urlset>
    XML
  end

  let(:page_html) do
    <<~HTML
      <html>
        <body>
          <img src="/wp-content/uploads/2024/10/present.jpg" />
        </body>
      </html>
    HTML
  end

  before do
    allow(target).to receive(:sub_dir).and_return(false)

    stub_request(:get, target.url('robots.txt')).to_return(body: "Sitemap: #{target.url('wp-sitemap.xml')}\n")
    stub_request(:get, %r{http://ex\.lo/(?:sitemap_index|sitemap|news-sitemap)\.xml(?:\.gz)?}).to_return(status: 404, body: '')
    stub_request(:get, %r{http://ex\.lo/wp-sitemap\.xml\.gz}).to_return(status: 404, body: '')
    stub_request(:get, target.url('wp-sitemap.xml')).to_return(body: sitemap_index)
    stub_request(:get, 'http://ex.lo/post-sitemap.xml').to_return(body: post_sitemap)
    stub_request(:get, 'http://ex.lo/media-sitemap.xml').to_return(body: media_sitemap)
    stub_request(:get, 'http://ex.lo/post-1/').to_return(body: page_html, headers: { 'Content-Type' => 'text/html' })
    stub_request(:get, 'http://ex.lo/wp-content/uploads/2024/10/orphan.jpg')
      .to_return(body: 'binary', headers: { 'Content-Type' => 'image/jpeg' })
    stub_request(:get, 'http://ex.lo/wp-content/uploads/2024/10/present.jpg')
      .to_return(body: 'binary', headers: { 'Content-Type' => 'image/jpeg' })
  end

  describe '#aggressive' do
    context 'when no anomaly evidence exists' do
      let(:media_sitemap) do
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <url><loc>http://ex.lo/wp-content/uploads/2024/10/present.jpg</loc></url>
          </urlset>
        XML
      end

      it 'returns nil' do
        expect(finder.aggressive).to be_nil
      end
    end

    context 'when an orphan sitemap media candidate exists' do
      it 'returns a MediaAnomalies finding with bounded examples' do
        found = finder.aggressive

        expect(found).to eql WPScan::Model::MediaAnomalies.new(
          target.url,
          confidence: 65,
          found_by: described_class::DIRECT_ACCESS,
          anomaly_count: 1,
          jetpack_context: false,
          interesting_entries: ['http://ex.lo/wp-content/uploads/2024/10/orphan.jpg']
        )
      end
    end

    context 'when a jetpack nested image sitemap discrepancy is detected' do
      before do
        stub_request(:get, target.url('wp-sitemap.xml')).to_return(body: <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <sitemap><loc>http://ex.lo/jetpack-image-sitemap.xml</loc></sitemap>
          </sitemapindex>
        XML

        stub_request(:get, 'http://ex.lo/jetpack-image-sitemap.xml')
          .to_return(body: File.binread(sitemap_fixtures.join('jetpack_image_urlset.xml')))
      end

      it 'matches anomalies per parent page and reports jetpack wording' do
        found = finder.aggressive

        expect(found.confidence).to eq(80)
        expect(found.interesting_entries).to include('http://ex.lo/wp-content/uploads/2024/10/orphan.jpg')
        expect(found.to_s).to include('declared in sitemap but absent from sampled rendered HTML')
      end
    end

    it 'finds the regression case for nested image:loc media absent from rendered HTML' do
      stub_request(:get, target.url('wp-sitemap.xml')).to_return(body: <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <sitemap><loc>http://ex.lo/jetpack-image-sitemap.xml</loc></sitemap>
        </sitemapindex>
      XML

      stub_request(:get, 'http://ex.lo/jetpack-image-sitemap.xml')
        .to_return(body: File.binread(sitemap_fixtures.join('jetpack_image_urlset.xml')))
      stub_request(:get, 'http://ex.lo/post-1/').to_return(body: <<~HTML, headers: { 'Content-Type' => 'text/html' })
        <html><body><img src="/wp-content/uploads/2024/10/present.jpg"/></body></html>
      HTML
      stub_request(:get, 'http://ex.lo/wp-content/uploads/2024/10/orphan.jpg')
        .to_return(body: 'binary', headers: { 'Content-Type' => 'image/jpeg' })

      found = finder.aggressive

      expect(found).not_to be_nil
      expect(found.anomaly_count).to eq(1)
      expect(found.interesting_entries).to eq(['http://ex.lo/wp-content/uploads/2024/10/orphan.jpg'])
    end

    it 'keeps interesting entries output bounded to 10 examples' do
      many_media = (1..15).map do |index|
        "<url><loc>http://ex.lo/wp-content/uploads/2024/10/orphan-#{index}.jpg</loc></url>"
      end.join

      stub_request(:get, 'http://ex.lo/media-sitemap.xml').to_return(body: <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          #{many_media}
        </urlset>
      XML

      (1..15).each do |index|
        stub_request(:get, "http://ex.lo/wp-content/uploads/2024/10/orphan-#{index}.jpg")
          .to_return(body: 'binary', headers: { 'Content-Type' => 'image/jpeg' })
      end

      found = finder.aggressive

      expect(found.anomaly_count).to eq(15)
      expect(found.interesting_entries.size).to eq(10)
    end

    it 'enforces the global request budget' do
      huge_post_sitemap = (1..120).map do |index|
        "<url><loc>http://ex.lo/post-#{index}/</loc></url>"
      end.join

      stub_request(:get, 'http://ex.lo/post-sitemap.xml').to_return(body: <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          #{huge_post_sitemap}
        </urlset>
      XML

      stub_request(:get, %r{http://ex\.lo/post-\d+/}).to_return(body: '<html></html>', headers: { 'Content-Type' => 'text/html' })

      finder.aggressive

      expect(a_request(:get, %r{http://ex\.lo/post-\d+/})).to have_been_made.times(50)
    end
  end
end
