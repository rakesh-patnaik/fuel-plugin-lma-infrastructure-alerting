#    Copyright 2015 Mirantis, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#
# == Resource: nagios::cgi
#
# Install and configure Nagios web interface
#
class nagios::cgi (
  $auth_provider = $nagios::params::cgi_auth_provider,
  $htaccess_user = $nagios::params::cgi_htaccess_user,
  $htaccess_password = $nagios::params::cgi_htaccess_password,
  $ldap_bind_user = $nagios::params::cgi_ldap_bind_user,
  $ldap_bind_password = $nagios::params::cgi_ldap_bind_password,
  $ldap_url = $nagios::params::cgi_ldap_url,
  $ldap_bind_dn = $nagios::params::cgi_ldap_bind_dn,
  $htpasswd_file = $nagios::params::cgi_htpasswd_file,
  $http_port = $nagios::params::cgi_http_port,
  $vhost_listen_ip = '*',
) inherits nagios::params {

  case $auth_provider {
    'htaccess': {
      $apache_default_mods = ['php', 'cgi', 'auth_basic', 'authn_user']
    }
    'ldap': {
      $apache_default_mods = ['php', 'cgi', 'auth_basic', 'ldap', 'authz_ldap']
    }
    default: {
      fail('Auth provider not supported!')
    }
  }

  ## Configure apache
  class { 'apache':
    # be good citizen by not erasing other configurations
    purge_configs       => false,
    default_confd_files => false,
    default_vhost       => false,
    # prerequists for Nagios CGI
    mpm_module          => 'prefork',
    default_mods        => $apache_default_mods,
    # allow to use the Puppet user resource later in the manifest
    manage_group        => false,
    manage_user         => false,
  }

  apache::listen { $http_port: }

  # Template uses these variables: http_port, vhost_listen_ip, cgi_htpasswd_file
  apache::custom_config { 'nagios':
    content => template("nagios/${nagios::params::apache_vhost_config_tpl}"),
  }

  $apache_user = $apache::user
  case $::osfamily {
    'Debian': {
      # Nagios CGI is provided by a dedicated package
      $package_name = $nagios::params::nagios_cgi_package
      package { $package_name:
        ensure  => present,
        require => Class[apache],
      }

      htpasswd { $htaccess_user:
        # TODO randomize salt?
        cryptpasswd => ht_md5($htaccess_password, 'salt'),
        target      => $htpasswd_file,
        require     => Package[$package_name],
      }

      # Fix a permission issue with Ubuntu to allow using external commands
      # through the web UI
      user { $apache_user:
        groups  => 'nagios',
        require => Class[apache],
      }

      # Apache needs to be restarted otherwise the CGI script won't have access
      # to the Nagios FIFO file
      file { '/var/lib/nagios3/rw':
        ensure  => directory,
        mode    => '0650',
        require => Package[$package_name],
        notify  => Class['apache::service']
      }

    }
    'Redhat': {
      htpasswd { $htaccess_user:
        # TODO randomize salt?
        cryptpasswd => ht_md5($htaccess_password, 'salt'),
        target      => $htpasswd_file,
      }
    }
    default: {
      fail('OS Familly not supported!')
    }
  }

  # Ensure read right for Apache
  file { $htpasswd_file:
    owner   => root,
    group   => $apache_user,
    mode    => '0640',
    require => Htpasswd[$htaccess_user],
  }
}
