module ::TwoFactorAuthentication
  class AuthenticationController < ApplicationController

    # User is not yet logged in, so skip login required check
    skip_before_action :check_if_login_required

    # Avoid catch-all from core resulting in methods
    before_action :only_post, only: :confirm_otp

    # Require authenticated user from the core to be present
    before_action :require_authenticated_user, only: [:request_otp, :confirm_otp, :retry]

    ##
    # Request token (if necessary) from the authenticated user
    def request_otp
      service = otp_service(@authenticated_user)

      # In case of mis-configuration, block all logins
      if manager.invalid_configuration?
        render_500 message: I18n.t('two_factor_authentication.error_is_enforced_not_active')
        return
      end

      # Allow users to register their own devices if they try to authenticate with an
      # non-existing 2nd factor.
      session[:authenticated_user_force_2fa] = service.needs_registration?

      if service.needs_registration?
        flash[:info] = I18n.t('two_factor_authentication.forced_registration.required_to_add_device')
        redirect_to new_forced_2fa_device_path
      elsif service.requires_token?
        perform_2fa_authentication service
      else
        complete_stage_redirect
      end
    end

    ##
    # Verify the validity of the entered token
    def confirm_otp
      login_if_otp_token_valid(@authenticated_user, params[:otp])
    end

    ##
    # Resend the OTP to the given device
    def retry
      service = service_from_resend_params
      perform_2fa_authentication service
    end

    private

    ##
    # Successful request of the token, render input form
    def successful_2fa_transmission(service, transmit)
      if transmit.result.present?
        flash[:notice] = transmit.result
      end

      flash.delete :error
      render_login_otp(service)
    end


    ##
    # Create a token service for the current user
    # with an optional override to use a non-default channel
    def otp_service(user, use_channel: nil, use_device: nil)
      ::TwoFactorAuthentication::TokenService.new user: user, use_channel: use_channel, use_device: use_device
    end

    ##
    # Detect overridden channel or device from params when trying to resend
    def service_from_resend_params
      channel = params[:use_channel].presence
      device =
        if params[:use_device].present?
          find_or_404 { @authenticated_user.otp_devices.find(params[:use_device]) }
        else
          nil
        end

      otp_service(@authenticated_user, use_channel: channel, use_device: device)
    end

    ##
    # Perform the 2FA authentication flow, sending the message
    # if the delivery requires it.
    def perform_2fa_authentication(service)
      transmit = service.request

      if transmit.success
        successful_2fa_transmission(service, transmit)
      else
        error = transmit.errors.full_messages.join(". ")
        default_message = t(:notice_account_otp_send_failed)
        flash.now[:error] = "#{default_message} #{error}"

        fail_login flash[:error]
      end
    end

    ##
    # Render OTP input form
    def render_login_otp(service)
      @service = service
      @strategy = service.strategy
      @user = service.user
      @used_device = service.device
      @active_devices = @user.otp_devices.get_active

      if params["back_url"]
        render :action => 'request_otp', :back_url => params["back_url"]
      else
        render :action => 'request_otp'
      end
    end

    ##
    # Check OTP string and login if valid
    def login_if_otp_token_valid(user, token_string)
      service = otp_service(user)
      result = service.verify(token_string)

      if result.success?
        complete_stage_redirect
      else
        fail_login(I18n.t(:notice_account_otp_invalid))
      end
    end

    # as the core currently provides a catchall route
    # we prevent unwanted requests by this filter
    def only_post
      unless request.post?
        head(:method_not_allowed)

        return false
      end
    end

    ##
    # fail the login
    def fail_login(msg)
      flash[:error] = msg
      failure_stage_redirect
    end

    ##
    # Ensure the authentication stage from the core provided the authenticated user
    def require_authenticated_user
      @authenticated_user = User.find(session[:authenticated_user_id])
    rescue ActiveRecord::RecordNotFound
      Rails.logger.error "Failed to find authenticated_user for 2FA authentication."
      failure_stage_redirect
    end

    def find_or_404(&block)
      yield
    rescue ActiveRecord::RecordNotFound
      render_404
      false
    end

    def manager
      ::OpenProject::TwoFactorAuthentication::TokenStrategyManager
    end

    ##
    # Complete this authentication step and return to core
    # logging in the user
    def complete_stage_redirect
      redirect_to authentication_stage_complete_path :two_factor_authentication
    end

    def failure_stage_redirect
      redirect_to authentication_stage_failure_path :two_factor_authentication
    end
  end
end
