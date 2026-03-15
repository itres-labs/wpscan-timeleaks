# frozen_string_literal: true

module WPScan
  module Controller
    # Controller for the PredictableMedia opt-in flag
    class PredictableMedia < CMSScanner::Controller::Base
      def cli_options
        [
          OptBoolean.new(
            ['--predictable-media',
             'Enable aggressive predictive media checks based on passively observed media URLs (experimental, low-noise).']
          )
        ]
      end
    end
  end
end
