# frozen_string_literal: true

module OC
  module RegistrationsController
    extend ActiveSupport::Concern
    extend ::Gitlab::Utils::Override

    # #672 -- a code that is offered has to be one we issued. No code at all is
    # fine; the instance decides separately whether signups need approval.
    def create
      if invite_code.present? && !::OC::Onboarding::InviteCodes.valid?(invite_code)
        flash[:alert] = _('Invite code is invalid.')
        cookies.delete(:invite_code, domain: ::Settings.gitlab.host)
        render :new
        return
      end

      super
    end

    private

    override :after_successful_create_hook
    def after_successful_create_hook(user)
      super

      ::OC::Onboarding::CreateDashboardProjectWorker.perform_async(user.id)
      record_invite_code(user)
    end

    # The interface choice is not a User attribute, so it is set here rather
    # than permitted into sign_up_params.
    #
    # Assigned only when the field arrives. `external` already carries what
    # User's attribute default took from user_default_external, which this
    # instance sets, so assigning unconditionally would make every client that
    # omits the field internal rather than leaving that policy alone.
    override :set_resource_fields
    def set_resource_fields
      resource.external = simple_interface? if oc_params.key?(:oc_interface)

      return if approved_by_invite_code?

      super
    end

    override :skip_confirmation?
    def skip_confirmation?
      super || approved_by_invite_code?
    end

    # A last name is optional here; upstream requires both.
    override :ensure_first_name_and_last_name_not_empty
    def ensure_first_name_and_last_name_not_empty
      names = params.permit(
        resource_name => [:first_name],
        :"new_#{resource_name}" => [:first_name]
      )
      first_name = names.dig(resource_name, :first_name) || names.dig(:"new_#{resource_name}", :first_name)

      return if first_name.present?

      resource.errors.add(_('First name'), _('cannot be blank'))

      render action: 'new'
    end

    def simple_interface?
      oc_params[:oc_interface] == 'deploy'
    end

    def invite_code
      oc_params[:invite_code].presence || cookies[:invite_code]
    end

    # The sign-up form posts under :user or, while the arkose challenge is on,
    # :new_user.
    def oc_params
      permitted = params.permit(
        resource_name => [:oc_interface, :invite_code],
        :"new_#{resource_name}" => [:oc_interface, :invite_code]
      )

      permitted[resource_name] || permitted[:"new_#{resource_name}"] || {}
    end

    def approved_by_invite_code?
      ::OC::Onboarding::InviteCodes.approves_without_confirmation?(invite_code)
    end

    def record_invite_code(user)
      return if invite_code.blank?

      ::UserCustomAttribute.upsert_custom_attributes(
        [{ user_id: user.id, key: 'invite_code', value: invite_code }]
      )
    end
  end
end
