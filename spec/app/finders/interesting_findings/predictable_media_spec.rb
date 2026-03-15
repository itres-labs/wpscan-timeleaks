# frozen_string_literal: true

describe WPScan::Finders::InterestingFindings::PredictableMedia do
  subject(:finder) { described_class.new(target) }

  let(:target) { WPScan::Target.new(url) }
  let(:url) { 'http://ex.lo/' }

  let(:homepage_html) do
    <<~HTML
      <html><body>
        <img src="/wp-content/uploads/2025/02/photo-0099-draft.jpg" />
      </body></html>
    HTML
  end

  before do
    allow(target).to receive(:sub_dir).and_return(false)
    allow(target).to receive(:homepage_res).and_return(
      Typhoeus::Response.new(code: 200, effective_url: url, body: homepage_html, headers: { 'Content-Type' => 'text/html' })
    )
    allow(target).to receive(:error_404_res).and_return(
      Typhoeus::Response.new(code: 404, effective_url: target.url('missing'), body: '<html>missing</html>',
                             headers: { 'Content-Type' => 'text/html' })
    )
  end

  describe '#aggressive' do
    context 'when opt-in flag is not enabled' do
      before { allow(WPScan::ParsedCli).to receive(:predictable_media).and_return(nil) }

      it 'returns nil and stays inert' do
        expect(WPScan::Browser).not_to receive(:get)

        expect(finder.aggressive).to be_nil
      end
    end

    context 'when enabled and a non-HTML candidate is found' do
      before do
        allow(WPScan::ParsedCli).to receive(:predictable_media).and_return(true)

        stub_request(:get, %r{http://ex\.lo/wp-content/uploads/this-should-not-exist-.*\.jpg})
          .to_return(status: 404, body: '<html>404 page</html>', headers: { 'Content-Type' => 'text/html' })

        allow(finder).to receive(:candidates_for_seed).and_return(['http://ex.lo/wp-content/uploads/2025/02/photo-0099.jpg'])

        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/photo-0099.jpg')
          .to_return(status: 200, body: 'x' * 64, headers: { 'Content-Type' => 'image/jpeg' })
      end

      it 'reports a PredictableMedia finding' do
        finding = finder.aggressive

        expect(finding).to eq(
          WPScan::Model::PredictableMedia.new(
            target.url,
            confidence: 75,
            found_by: described_class::DIRECT_ACCESS,
            predicted_count: 1,
            interesting_entries: ['http://ex.lo/wp-content/uploads/2025/02/photo-0099.jpg']
          )
        )
      end
    end


    context 'when media anomalies seed context is available' do
      before do
        allow(WPScan::ParsedCli).to receive(:predictable_media).and_return(true)
        allow(target).to receive(:content_dir).and_return('wp-content')

        target.instance_variable_set(
          :@predictable_media_seed_context,
          {
            suspicious_urls: ['http://ex.lo/wp-content/uploads/2025/02/image-26.png'],
            discovered_urls: ['http://ex.lo/wp-content/uploads/2025/02/image-26.png']
          }
        )

        stub_request(:get, %r{http://ex\.lo/wp-content/uploads/this-should-not-exist-.*\.jpg})
          .to_return(status: 404, body: '<html>404 page</html>', headers: { 'Content-Type' => 'text/html' })
      end

      it 'reuses discovered suspicious URLs as seeds before passive seeds' do
        expect(finder).to receive(:candidates_for_seed).with('http://ex.lo/wp-content/uploads/2025/02/image-26.png')
                                                   .ordered.and_return([])
        expect(finder).to receive(:candidates_for_seed).with('http://ex.lo/wp-content/uploads/2025/02/photo-0099-draft.jpg')
                                                   .ordered.and_return([])

        finder.aggressive
      end

      it 'finds numeric neighbors from a discovered sitemap media URL' do
        allow(finder).to receive(:passive_media_seeds).and_return([])
        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/image-25.png')
          .to_return(status: 404, body: '')
        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/image-27.png')
          .to_return(status: 200, body: 'x' * 64, headers: { 'Content-Type' => 'image/png' })
        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/image-28.png')
          .to_return(status: 404, body: '')
        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/image-24.png')
          .to_return(status: 404, body: '')

        finding = finder.aggressive

        expect(finding).not_to be_nil
        expect(finding.interesting_entries).to eq(['http://ex.lo/wp-content/uploads/2025/02/image-27.png'])
      end

      it 'reports nothing when discovered candidates resolve to baseline-like HTML' do
        allow(finder).to receive(:passive_media_seeds).and_return([])
        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/image-25.png')
          .to_return(status: 200, body: '<html>404 page</html>', headers: { 'Content-Type' => 'text/html' })
        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/image-27.png')
          .to_return(status: 200, body: '<html>404 page</html>', headers: { 'Content-Type' => 'text/html' })
        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/image-28.png')
          .to_return(status: 200, body: '<html>404 page</html>', headers: { 'Content-Type' => 'text/html' })
        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/image-24.png')
          .to_return(status: 200, body: '<html>404 page</html>', headers: { 'Content-Type' => 'text/html' })

        expect(finder.aggressive).to be_nil
      end
    end
    context 'when baseline is 200-for-404 HTML' do
      before do
        allow(WPScan::ParsedCli).to receive(:predictable_media).and_return(true)

        stub_request(:get, %r{http://ex\.lo/wp-content/uploads/this-should-not-exist-.*\.jpg})
          .to_return(status: 200, body: '<html>not found template</html>', headers: { 'Content-Type' => 'text/html' })

        allow(finder).to receive(:candidates_for_seed).and_return(['http://ex.lo/wp-content/uploads/2025/02/photo-0099.jpg'])

        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/photo-0099.jpg')
          .to_return(status: 200, body: '<html>not found template</html>', headers: { 'Content-Type' => 'text/html' })
      end

      it 'rejects the candidate' do
        expect(finder.aggressive).to be_nil
      end
    end

    it 'enforces the max candidate request budget' do
      allow(WPScan::ParsedCli).to receive(:predictable_media).and_return(true)

      seeds = (1..200).map { |i| "http://ex.lo/wp-content/uploads/2025/02/seed-#{i}.jpg" }

      allow(finder).to receive(:baseline_404).and_return(
        soft_404: false,
        html_signature: nil,
        html_size: nil,
        html_code: nil
      )
      allow(finder).to receive(:observed_media_seeds).and_return(seeds)
      allow(finder).to receive(:candidates_for_seed) do |seed|
        seed_num = seed[/seed-(\d+)/, 1]

        [
          "http://ex.lo/wp-content/uploads/2025/02/candidate-#{seed_num}-a.jpg",
          "http://ex.lo/wp-content/uploads/2025/02/candidate-#{seed_num}-b.jpg"
        ]
      end

      stub_request(:get, %r{http://ex\.lo/wp-content/uploads/2025/02/candidate-\d+-(?:a|b)\.jpg})
        .to_return(status: 404, body: '')

      finder.aggressive

      expect(a_request(:get, %r{http://ex\.lo/wp-content/uploads/2025/02/candidate-\d+-(?:a|b)\.jpg}))
        .to have_been_made.times(300)
    end

    context 'when candidate response looks like baseline HTML' do
      before do
        allow(WPScan::ParsedCli).to receive(:predictable_media).and_return(true)

        stub_request(:get, %r{http://ex\.lo/wp-content/uploads/this-should-not-exist-.*\.jpg})
          .to_return(status: 404, body: '<html><body>custom not found body</body></html>',
                     headers: { 'Content-Type' => 'text/html' })

        allow(finder).to receive(:candidates_for_seed).and_return(['http://ex.lo/wp-content/uploads/2025/02/photo-0099.jpg'])

        stub_request(:get, 'http://ex.lo/wp-content/uploads/2025/02/photo-0099.jpg')
          .to_return(status: 200, body: '<html><body>custom not found body</body></html>',
                     headers: { 'Content-Type' => 'text/html' })
      end

      it 'does not report a finding' do
        expect(finder.aggressive).to be_nil
      end
    end
  end

  describe 'candidate generation helpers' do
    it 'generates nearby numeric neighbors preserving zero-padding' do
      expect(finder.send(:numeric_neighbors, '/wp-content/uploads/2025/02/photo-0099')).to include(
        '/wp-content/uploads/2025/02/photo-0098',
        '/wp-content/uploads/2025/02/photo-0100'
      )
    end

    it 'strips one sensitive suffix' do
      expect(finder.send(:strip_sensitive_suffix, '/wp-content/uploads/2025/02/original-redacted'))
        .to eq('/wp-content/uploads/2025/02/original')
    end
  end
end
