# frozen_string_literal: true

module Api
  module V1
    class TenantsController < ApplicationController
      skip_before_action :verify_authenticity_token

      before_action :check_multitenancy
      before_action :set_tenant, only: [:show, :destroy]

      # Return a list of all tenants
      # GET /bigbluebutton/api/api/v1/tenants
      #
      # Successful response:
      # [
      #   {
      #     "id": String,
      #     "name": String,
      #     "secrets": String,
      #   },
      #   ...
      # ]
      def index
        tenants = Tenant.all

        if tenants.empty?
          render json: { message: 'No tenants exist' }, status: :ok
        else
          tenants_list = tenants.map do |tenant|
            {
              id: tenant.id,
              name: tenant.name,
              secrets: tenant.secrets
            }
          end

          render json: tenants_list, status: :ok
        end
      end

      # Retrieve the information for a specific tenant
      # GET /bigbluebutton/api/api/v1/tenants/:id
      #
      # Successful response:
      # [
      #   {
      #     "id": String,
      #     "name": String,
      #     "secrets": String,
      #   },
      #   ...
      # ]
      def show
        render json: @tenant, status: :ok
      end

      # Add a new tenant
      # POST /bigbluebutton/api/api/v1/tenants
      #
      # Expected params:
      # {
      #   "tenant": {
      #     "name": String,                 # Required: Name of the tenant
      #     "secrets": String,              # Required: Tenant secret(s)
      #   }
      # }
      def create
        if tenant_params[:name].blank? || tenant_params[:secrets].blank?
          render json: { message: 'Error: both name and secrets are required to create a Tenant' }, status: :unprocessable_entity
        else
          tenant = Tenant.create(tenant_params)
          render json: { message: 'OK', id: tenant.id }, status: :created
        end
      end

      # Delete tenant
      # DELETE /bigbluebutton/api/api/v1/servers/:id
      def destroy
        @tenant.destroy!
        render json: { message: 'OK' }, status: :ok
      rescue ApplicationRedisRecord::RecordNotDestroyed => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def set_tenant
        @tenant = Tenant.find(params[:id])
      rescue ApplicationRedisRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end

      def tenant_params
        params.require(:tenant).permit(:name, :secrets)
      end

      def check_multitenancy
        return render json: { message: "Multitenancy is disabled" }, status: :precondition_failed unless Rails.configuration.x.multitenancy_enabled
      end
    end
  end
end
