#
# Cookbook Name:: jenkins
# HWRP:: credentials
#
# Author:: Seth Chisamore <schisamo@getchef.com>
#
# Copyright 2013-2014, Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

class Chef
  class Resource::JenkinsCredentials < Resource
    require 'securerandom'

    include Jenkins::Helper

    identity_attr :username

    attr_writer :exists

    def initialize(name, run_context = nil)
      super

      @resource_name = :jenkins_credentials
      @provider = Provider::JenkinsCredentials

      # Set default actions and allowed actions
      @action = :create
      @allowed_actions.push(:create, :delete)

      # Set the name attribute and default attributes
      @username    = name
      # Matches how Jenkins generates IDs internally
      # https://github.com/jenkinsci/credentials-plugin/blob/master/src/main/java/com/cloudbees/plugins/credentials/common/IdCredentials.java#L100
      @id          = SecureRandom.uuid
      @description = "Credentials for #{username} - created by Chef"

      # State attributes that are set by the provider
      @exists = false
    end

    #
    # A unique identifier for the credentials.
    #
    # @param [String] arg
    # @return [String]
    #
    def id(arg = nil)
      set_or_return(:id, arg, kind_of: String, regex: UUID_REGEX)
    end

    #
    # The description of the credentials.
    #
    # @param [String] arg
    # @return [String]
    #
    def description(arg = nil)
      set_or_return(:description, arg, kind_of: String)
    end

    #
    # The username of the credentials.
    #
    # @param [String] arg
    # @return [String]
    #
    def username(arg = nil)
      set_or_return(:username, arg, kind_of: String)
    end

    #
    # Determine if the credentials exists on the master. This value is
    # set by the provider when the current resource is loaded.
    #
    # @return [Boolean]
    #
    def exists?
      !!@exists
    end
  end
end

class Chef
  class Provider::JenkinsCredentials < Provider
    require 'json'
    require 'openssl'

    include Jenkins::Helper

    def load_current_resource
      @current_resource ||= Resource::JenkinsCredentials.new(new_resource.name)

      if current_credentials
        @current_resource.exists = true
        @current_resource.id(current_credentials[:id])
        @current_resource.description(current_credentials[:description])
        @current_resource.username(current_credentials[:username])
      end
    end

    #
    # This provider supports why-run mode.
    #
    def whyrun_supported?
      true
    end

    #
    # Create the given credentials.
    #
    def action_create
      if current_resource.exists? && correct_config?
        Chef::Log.debug("#{new_resource} exists - skipping")
      else
        converge_by("Create #{new_resource}") do
          executor.groovy! <<-EOH.gsub(/ ^{12}/, '')
            import jenkins.model.*
            import com.cloudbees.plugins.credentials.*
            import com.cloudbees.plugins.credentials.domains.*
            import hudson.plugins.sshslaves.*;

            global_domain = Domain.global()
            credentials_store =
              Jenkins.instance.getExtensionList(
                'com.cloudbees.plugins.credentials.SystemCredentialsProvider'
              )[0].getStore()

            #{credentials_groovy}

            // Create or update the credentials in the Jenkins instance
            #{credentials_for_username_groovy(new_resource.username, 'existing_credentials')}

            if(existing_credentials != null) {
              credentials_store.updateCredentials(
                global_domain,
                existing_credentials,
                credentials
              )
            } else {
              credentials_store.addCredentials(global_domain, credentials)
            }
          EOH
        end
      end
    end

    #
    # Delete the given credentials.
    #
    def action_delete
      if current_resource.exists?
        converge_by("Delete #{new_resource}") do
          executor.groovy! <<-EOH.gsub(/ ^{12}/, '')
            import jenkins.model.*
            import com.cloudbees.plugins.credentials.*;

            global_domain = com.cloudbees.plugins.credentials.domains.Domain.global()
            credentials_store =
              Jenkins.instance.getExtensionList(
                'com.cloudbees.plugins.credentials.SystemCredentialsProvider'
              )[0].getStore()

            #{credentials_for_username_groovy(new_resource.username, 'existing_credentials')}

            if(existing_credentials != null) {
              credentials_store.removeCredentials(
                global_domain,
                existing_credentials
              )
            }
          EOH
        end
      else
        Chef::Log.debug("#{new_resource} does not exist - skipping")
      end
    end

    protected

    #
    # Returns a Groovy snippet that creates an instance of the
    # credentail's implementation. The credentials instance should be
    # set to a Groovy variable named `credentials`.
    #
    # @abstract
    # @return [String]
    #
    def credentials_groovy
      fail NotImplementedError, 'You must implement #credentials_groovy.'
    end

    #
    # Maps a credentails's resource attribute name to the equivalent
    # property in the Groovy representation. This mapping is useful in
    # Ruby/Groovy serialization/deserialization.
    #
    # @return [Hash]
    #
    # @example
    #   {password: 'credentials.password.plainText'}
    #
    def attribute_to_property_map
      {}
    end

    #
    # Loads the current credential into a Hash.
    #
    def current_credentials
      return @current_credentials if @current_credentials

      Chef::Log.debug "Load #{new_resource} credentials information"

      credentials_attributes = []
      attribute_to_property_map.each_pair do |resource_attribute, groovy_property|
        credentials_attributes <<
        "current_credentials['#{resource_attribute}'] = #{groovy_property}"
      end

      json = executor.groovy! <<-EOH.gsub(/ ^{8}/, '')
        import com.cloudbees.plugins.credentials.impl.*;
        import com.cloudbees.jenkins.plugins.sshcredentials.impl.*;

        #{credentials_for_username_groovy(new_resource.username, 'credentials')}

        if(credentials == null) {
          return null
        }

        current_credentials = [
          id:credentials.id,
          description:credentials.description,
          username:credentials.username
        ]

        #{credentials_attributes.join("\n")}

        builder = new groovy.json.JsonBuilder(current_credentials)
        println(builder)
      EOH

      return nil if json.nil? || json.empty?

      @current_credentials = JSON.parse(json, symbolize_names: true)

      # Values that were serialized as nil/null are deserialized as an
      # empty string! :( Let's ensure we convert back to nil.
      @current_credentials = convert_blank_values_to_nil(@current_credentials)
    end

    #
    # Helper method for determining if the given JSON is in sync with the
    # current configuration on the Jenkins instance.
    #
    # @return [Boolean]
    #
    def correct_config?
      wanted_credentials = {
        description: new_resource.description,
        username: new_resource.username
      }

      attribute_to_property_map.keys.each do |key|
        wanted_credentials[key] = new_resource.send(key)
      end

      # Don't compare the ID as it is generated
      current_credentials.dup.tap { |c| c.delete(:id) } == wanted_credentials
    end
  end
end