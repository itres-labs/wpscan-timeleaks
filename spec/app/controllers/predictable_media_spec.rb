# frozen_string_literal: true

describe WPScan::Controller::PredictableMedia do
  subject(:controller) { described_class.new }
  let(:cli_args) { '--url http://ex.lo/' }

  before do
    WPScan::ParsedCli.options = rspec_parsed_options(cli_args)
  end

  describe '#cli_options' do
    it 'defines the predictable_media option' do
      expect(controller.cli_options.map(&:to_sym)).to eq(%i[predictable_media])
    end
  end
end
