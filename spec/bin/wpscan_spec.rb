# frozen_string_literal: true

describe 'bin/wpscan' do
  let(:controllers) { [] }
  let(:scan) { instance_double(WPScan::Scan, controllers: controllers, run: nil) }
  let(:bin_wpscan) { File.expand_path('../../bin/wpscan', __dir__) }

  it 'registers the PredictableMedia controller' do
    expect(WPScan::Scan).to receive(:new) do |&block|
      block.call(scan)
    end

    load bin_wpscan

    expect(controllers.map(&:class)).to include(WPScan::Controller::PredictableMedia)
  end
end
