# frozen_string_literal: true

describe WPScan::Finders::InterestingFindings::MediaAnomalies do
  subject(:finder) { described_class.new(target) }

  let(:target) { WPScan::Target.new(url) }
  let(:url) { 'http://ex.lo/' }

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
        expect(found.to_s).to include('not observed in sampled public pages')
      end
    end

    context 'when anomalies are computed' do
      it 'stores predictable media seed context on target for PR3 reuse' do
        finder.aggressive

        context = target.instance_variable_get(:@predictable_media_seed_context)

        expect(context[:suspicious_urls]).to eq(['http://ex.lo/wp-content/uploads/2024/10/orphan.jpg'])
        expect(context[:discovered_urls]).to include(
          'http://ex.lo/wp-content/uploads/2024/10/present.jpg',
          'http://ex.lo/wp-content/uploads/2024/10/orphan.jpg'
        )
      end
    end

    context 'when a jetpack sitemap discrepancy is detected' do
      before do
        stub_request(:get, target.url('wp-sitemap.xml')).to_return(body: <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <sitemap><loc>http://ex.lo/jetpack-sitemap.xml</loc></sitemap>
            <sitemap><loc>http://ex.lo/post-sitemap.xml</loc></sitemap>
          </sitemapindex>
        XML

        stub_request(:get, 'http://ex.lo/jetpack-sitemap.xml').to_return(body: <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:jp="https://jetpack.com/">
            <url><loc>http://ex.lo/wp-content/uploads/2024/10/orphan.jpg</loc></url>
          </urlset>
        XML
      end

      it 'returns a finding with jetpack wording and confidence' do
        found = finder.aggressive

        expect(found.confidence).to eq(80)
        expect(found.to_s).to include('declared in sitemap but absent from sampled rendered HTML')
      end
    end

    context 'when jetpack image sitemap entries declare media via nested image:loc' do
      before do
        stub_request(:get, target.url('wp-sitemap.xml')).to_return(body: <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <sitemap><loc>http://ex.lo/image-sitemap.xml</loc></sitemap>
            <sitemap><loc>http://ex.lo/post-sitemap.xml</loc></sitemap>
          </sitemapindex>
        XML

        stub_request(:get, 'http://ex.lo/image-sitemap.xml').to_return(body: <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset
            xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
            xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"
            xmlns:jp="https://jetpack.com/">
            <url>
              <loc>http://ex.lo/post-1/</loc>
              <image:image>
                <image:loc>http://ex.lo/wp-content/uploads/2024/10/present.jpg</image:loc>
              </image:image>
              <image:image>
                <image:loc>http://ex.lo/wp-content/uploads/2024/10/orphan.jpg</image:loc>
              </image:image>
            </url>
          </urlset>
        XML
      end

      it 'detects anomalies from nested image:loc declarations' do
        found = finder.aggressive

        expect(found.confidence).to eq(80)
        expect(found.interesting_entries).to eq(['http://ex.lo/wp-content/uploads/2024/10/orphan.jpg'])
      end
    end

    context 'when sitemap and rendered html use canonical variants of the same media URL' do
      let(:media_sitemap) do
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <url><loc>https://i0.wp.com/ex.lo/wp-content/uploads/2024/10/present.jpg?resize=1200%2C800</loc></url>
          </urlset>
        XML
      end

      let(:page_html) do
        <<~HTML
          <html>
            <body>
              <img src="http://ex.lo/wp-content/uploads/2024/10/present.jpg?ver=123#view" />
            </body>
          </html>
        HTML
      end

      it 'does not report an anomaly for equivalent upload path identifiers' do
        expect(finder.aggressive).to be_nil
      end
    end

    context 'when image sitemap links a parent post and media on labs.itresit.es style data' do
      let(:url) { 'https://labs.itresit.es/' }

      before do
        stub_request(:get, target.url('robots.txt')).to_return(body: "Sitemap: #{target.url('wp-sitemap.xml')}\n")
        stub_request(:get, %r{https://labs\.itresit\.es/(?:sitemap_index|sitemap|news-sitemap)\.xml(?:\.gz)?}).to_return(status: 404, body: '')
        stub_request(:get, %r{https://labs\.itresit\.es/wp-sitemap\.xml\.gz}).to_return(status: 404, body: '')

        stub_request(:get, target.url('wp-sitemap.xml')).to_return(body: <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <sitemap><loc>https://labs.itresit.es/wp-sitemap-posts-post-1.xml</loc></sitemap>
            <sitemap><loc>https://labs.itresit.es/wp-sitemap-posts-post-1-image-sitemap.xml</loc></sitemap>
          </sitemapindex>
        XML

        stub_request(:get, 'https://labs.itresit.es/wp-sitemap-posts-post-1.xml').to_return(body: <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            <url><loc>https://labs.itresit.es/2025/02/17/sample-post/</loc></url>
          </urlset>
        XML

        stub_request(:get, 'https://labs.itresit.es/wp-sitemap-posts-post-1-image-sitemap.xml').to_return(body: <<~XML)
          <?xml version="1.0" encoding="UTF-8"?>
          <urlset
            xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
            xmlns:image="http://www.google.com/schemas/sitemap-image/1.1"
            xmlns:jetpack="https://jetpack.com/">
            <url>
              <loc>https://labs.itresit.es/2025/02/17/sample-post/</loc>
              <image:image>
                <image:loc>https://labs.itresit.es/wp-content/uploads/2025/02/sanitized.jpg</image:loc>
              </image:image>
              <image:image>
                <image:loc>https://labs.itresit.es/wp-content/uploads/2025/02/original-redacted.jpg</image:loc>
              </image:image>
            </url>
          </urlset>
        XML

        stub_request(:get, 'https://labs.itresit.es/2025/02/17/sample-post/').to_return(
          body: '<html><body><img src="/wp-content/uploads/2025/02/sanitized.jpg"></body></html>',
          headers: { 'Content-Type' => 'text/html' }
        )
        stub_request(:get, 'https://labs.itresit.es/wp-content/uploads/2025/02/original-redacted.jpg').to_return(
          body: 'binary', headers: { 'Content-Type' => 'image/jpeg' }
        )
      end

      it 'reports nested image sitemap media not observed in sampled rendered HTML' do
        found = finder.aggressive

        expect(found).not_to be_nil
        expect(found.interesting_entries).to eq(['https://labs.itresit.es/wp-content/uploads/2025/02/original-redacted.jpg'])
      end
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

    it 'rejects 200 JSON soft-error payloads during anomaly verification' do
      stub_request(:get, 'http://ex.lo/wp-content/uploads/2024/10/orphan.jpg')
        .to_return(body: '{"error":"not found"}', headers: { 'Content-Type' => 'application/json' })

      expect(finder.aggressive).to be_nil
    end

    it 'does not create false anomalies when sampled page redirects from declared sitemap URL' do
      allow(WPScan::Browser).to receive(:get).and_call_original
      allow(WPScan::Browser).to receive(:get).with('http://ex.lo/post-1/').and_return(
        Typhoeus::Response.new(
          code: 200,
          effective_url: 'https://ex.lo/post-1',
          body: '<html><body><img src="https://cdn.ex.lo/wp-content/uploads/2024/10/present.jpg?resize=600%2C300"></body></html>',
          headers: { 'Content-Type' => 'text/html' }
        )
      )

      found = finder.aggressive

      expect(found).not_to be_nil
      expect(found.interesting_entries).to eq(['http://ex.lo/wp-content/uploads/2024/10/orphan.jpg'])
    end

    it 'keeps mapped diffing when declared page URL matches a sampled effective URL alias' do
      stub_request(:get, 'http://ex.lo/media-sitemap.xml').to_return(body: <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
                xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
          <url>
            <loc>https://ex.lo/post-1</loc>
            <image:image><image:loc>http://ex.lo/wp-content/uploads/2024/10/present.jpg</image:loc></image:image>
            <image:image><image:loc>http://ex.lo/wp-content/uploads/2024/10/orphan.jpg</image:loc></image:image>
          </url>
        </urlset>
      XML

      allow(WPScan::Browser).to receive(:get).and_call_original
      allow(WPScan::Browser).to receive(:get).with('http://ex.lo/post-1/').and_return(
        Typhoeus::Response.new(
          code: 200,
          effective_url: 'https://ex.lo/post-1',
          body: '<html><body><img src="/wp-content/uploads/2024/10/present.jpg"></body></html>',
          headers: { 'Content-Type' => 'text/html' }
        )
      )

      found = finder.aggressive

      expect(found).not_to be_nil
      expect(found.interesting_entries).to eq(['http://ex.lo/wp-content/uploads/2024/10/orphan.jpg'])
    end

    it 'does not diff unsampled pages as empty observations' do
      stub_request(:get, 'http://ex.lo/post-sitemap.xml').to_return(body: <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>http://ex.lo/post-1/</loc></url>
          <url><loc>http://ex.lo/post-2/</loc></url>
        </urlset>
      XML

      stub_request(:get, 'http://ex.lo/media-sitemap.xml').to_return(body: <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
                xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
          <url>
            <loc>http://ex.lo/post-1/</loc>
            <image:image><image:loc>http://ex.lo/wp-content/uploads/2024/10/present.jpg</image:loc></image:image>
          </url>
          <url>
            <loc>http://ex.lo/post-2/</loc>
            <image:image><image:loc>http://ex.lo/wp-content/uploads/2024/10/unsampled.jpg</image:loc></image:image>
          </url>
        </urlset>
      XML

      stub_request(:get, 'http://ex.lo/post-1/').to_return(
        status: 200,
        body: '<html><body><img src="/wp-content/uploads/2024/10/present.jpg"></body></html>',
        headers: { 'Content-Type' => 'text/html' }
      )
      stub_request(:get, 'http://ex.lo/post-2/').to_return(status: 500, body: '')

      expect(finder.aggressive).to be_nil
    end

    it 'keeps unsampled declared media out of anomalies while still reporting direct sitemap media anomalies' do
      stub_request(:get, 'http://ex.lo/post-sitemap.xml').to_return(body: <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url><loc>http://ex.lo/post-1/</loc></url>
          <url><loc>http://ex.lo/post-2/</loc></url>
        </urlset>
      XML

      stub_request(:get, 'http://ex.lo/media-sitemap.xml').to_return(body: <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"
                xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">
          <url><loc>http://ex.lo/wp-content/uploads/2024/10/orphan.jpg</loc></url>
          <url>
            <loc>http://ex.lo/post-2/</loc>
            <image:image><image:loc>http://ex.lo/wp-content/uploads/2024/10/unsampled.jpg</image:loc></image:image>
          </url>
        </urlset>
      XML

      stub_request(:get, 'http://ex.lo/post-1/').to_return(
        status: 200,
        body: '<html><body><img src="/wp-content/uploads/2024/10/present.jpg"></body></html>',
        headers: { 'Content-Type' => 'text/html' }
      )
      stub_request(:get, 'http://ex.lo/post-2/').to_return(status: 504, body: '')
      stub_request(:get, 'http://ex.lo/wp-content/uploads/2024/10/unsampled.jpg')
        .to_return(body: 'binary', headers: { 'Content-Type' => 'image/jpeg' })

      found = finder.aggressive

      expect(found).not_to be_nil
      expect(found.interesting_entries).to eq(['http://ex.lo/wp-content/uploads/2024/10/orphan.jpg'])
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
