# Copyright 2015 Mirantis, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

notice('fuel-plugin-lma-infrastructure-alerting: nagios.pp')

$cluster_ip = hiera('lma::infrastructure_alerting::cluster_ip')
$env_id = hiera('deployment_id')
$fuel_version = 0 + hiera('fuel_version')

$plugin = hiera('lma_infrastructure_alerting')
$password = $plugin['nagios_password']
if $notify_warning == false and
  $notify_critical == false and
  $notify_unknown == false and
  $notify_recovery == false {

  $send_to = undef
  $send_from = undef
  $smtp_host = undef
  $smtp_auth = undef
  $smtp_password = undef
} else {
  $send_to = $plugin['send_to']
  $send_from = $plugin['send_from']
  $smtp_host = $plugin['smtp_host']
  $smtp_auth = $plugin['smtp_auth']
  $smtp_user = $plugin['smtp_user']
  $smtp_password = $plugin['smtp_password']

  $notify_warning = $plugin['notify_warning']
  $notify_critical = $plugin['notify_critical']
  $notify_unknown = $plugin['notify_unknown']
  $notify_recovery = $plugin['notify_recovery']
}

$apache_config_dir = hiera('lma::infrastructure_alerting::apache_dir')
$nagios_vip = hiera('lma::infrastructure_alerting::vip')

$nagios_ui = hiera_hash('lma::infrastructure_alerting::nagios_ui')
$nagios_ui_vip = $nagios_ui['vip']
$apache_port = $nagios_ui['apache_port']

$tls_enabled = $nagios_ui['tls_enabled']

$lma_collector = hiera_hash('lma_collector', {})

if $lma_collector['gse_cluster_global'] {
  $service_clusters = keys($lma_collector['gse_cluster_global']['clusters'])
}else{
  $service_clusters = []
}

if $lma_collector['gse_cluster_node'] {
  $node_clusters = keys($lma_collector['gse_cluster_node']['clusters'])
}else{
  $node_clusters = []
}

# Install and configure nagios server for StackLight
class { 'lma_infra_alerting::nagios':
  httpd_dir               => $apache_config_dir,
  http_password           => $password,
  http_port               => $apache_port,
  nagios_ui_address       => $nagios_ui_vip,
  nagios_address          => $nagios_vip,
  ui_tls_enabled          => $tls_enabled,
  ui_certificate_filename => $nagios_ui['ssl_cert_path'],
  ui_certificate_hostname => $nagios_ui['hostname'],

}

class { 'lma_infra_alerting::nagios::vhost':
  openstack_deployment_name => $env_id,
  openstack_management_vip  => $cluster_ip,
  global_clusters           => $service_clusters,
  node_clusters             => $node_clusters,
  require                   => Class['lma_infra_alerting::nagios'],
}

$configure_arp_filter_for_vip = '/usr/local/bin/configure_arp_filter_for_vip'
file { $configure_arp_filter_for_vip:
  ensure => present,
  source => 'puppet:///modules/lma_infra_alerting/configure_arp_filter_for_vip',
  mode   => '0755',
  owner  => 'root',
  group  => 'root',
}

file { 'ocf-ns_apache':
  ensure  => present,
  path    => '/usr/lib/ocf/resource.d/fuel/ocf-ns_apache',
  source  => 'puppet:///modules/lma_infra_alerting/ocf-ns_apache',
  mode    => '0755',
  owner   => 'root',
  group   => 'root',
  require => File[$configure_arp_filter_for_vip],
}

file { 'ocf-ns_nagios':
  ensure => present,
  path   => '/usr/lib/ocf/resource.d/fuel/ocf-ns_nagios',
  source => 'puppet:///modules/lma_infra_alerting/ocf-ns_nagios',
  mode   => '0755',
  owner  => 'root',
  group  => 'root',
}

# This is required so Apache and Nagios can bind to the VIP addresses
exec { 'net.ipv4.ip_nonlocal_bind':
  command => '/sbin/sysctl -w net.ipv4.ip_nonlocal_bind=1',
  unless  => '/sbin/sysctl -n net.ipv4.ip_nonlocal_bind | /bin/grep 1',
}

# Service must be defined for Pacemaker resources
service { 'apache2-nagios':
  ensure     => 'running',
  enable     => true,
  hasstatus  => true,
  hasrestart => true,
}

if $fuel_version < 9.0 {
  # Apache2 resources for Pacemaker
  pacemaker_wrappers::service { 'apache2-nagios':
    primitive_type => 'ocf-ns_apache',
    parameters     => {
      'ns'         => 'infrastructure_alerting',
      'status_url' => "http://${nagios_vip}:${apache_port}/server-status",
      'config'     => "${apache_config_dir}/apache2.conf",
    },
    metadata       => {
      'migration-threshold' => '3',
      'failure-timeout'     => '120',
    },
    operations     => {
      'monitor' => {
        'interval' => '30',
        'timeout'  => '60'
      },
      'start'   => {
        'timeout' => '60'
      },
      'stop'    => {
        'timeout' => '60'
      },
    },
    prefix         => false,
    use_handler    => false,
    require        => [File['ocf-ns_apache'], Exec['net.ipv4.ip_nonlocal_bind'], Class['lma_infra_alerting::nagios']],
  }

  cs_rsc_colocation { 'infrastructure_alerting_vip-with-apache2-nagios':
    ensure     => present,
    score      => 'INFINITY',
    primitives => [
      'vip__infrastructure_alerting_mgmt_vip',
      'apache2-nagios'
    ],
    require    => Cs_resource['apache2-nagios'],
  }

  # Nagios resources for Pacemaker
  pacemaker_wrappers::service { 'nagios3':
    primitive_type => 'ocf-ns_nagios',
    parameters     => {
      'ns' => 'infrastructure_alerting',
    },
    metadata       => {
      'migration-threshold' => '3',
      'failure-timeout'     => '120',
    },
    operations     => {
      'monitor' => {
        'interval' => '30',
        'timeout'  => '60'
      },
      'start'   => {
        'timeout' => '60'
      },
      'stop'    => {
        'timeout' => '60'
      },
    },
    prefix         => false,
    use_handler    => false,
    require        => [File['ocf-ns_nagios'], Exec['net.ipv4.ip_nonlocal_bind'], Class['lma_infra_alerting::nagios']],
  }

  cs_rsc_colocation { 'infrastructure_alerting_vip-with-nagios':
    ensure     => present,
    score      => 'INFINITY',
    primitives => [
      'vip__infrastructure_alerting_mgmt_vip',
      'nagios3'
    ],
    require    => Cs_resource['nagios3'],
  }

  # The two VIPs must be colocated
  # This assumes that the VIPs have already been created
  cs_rsc_colocation { 'ui_vip-with-wsgi_vip':
    ensure     => present,
    score      => 'INFINITY',
    primitives => [
      'vip__infrastructure_alerting_mgmt_vip',
      'vip__infrastructure_alerting_ui'
    ],
  }
} else {
  # Apache2 resources for Pacemaker
  pacemaker::service { 'apache2-nagios':
    primitive_type   => 'ocf-ns_apache',
    parameters       => {
      'ns'         => 'infrastructure_alerting',
      'status_url' => "http://${nagios_vip}:${apache_port}/server-status",
      'config'     => "${apache_config_dir}/apache2.conf",
    },
    complex_type     => 'clone',
    complex_metadata => {
      'migration-threshold' => '3',
      'failure-timeout'     => '120',
    },
    operations       => {
      'monitor' => {
        'interval' => '30',
        'timeout'  => '60'
      },
      'start'   => {
        'timeout' => '60'
      },
      'stop'    => {
        'timeout' => '60'
      },
    },
    prefix           => false,
    use_handler      => false,
    require          => [File['ocf-ns_apache'], Exec['net.ipv4.ip_nonlocal_bind'], Class['lma_infra_alerting::nagios']],
  }

  pcmk_colocation { 'infrastructure_alerting_vip-with-apache2-nagios':
    ensure  => present,
    score   => 'INFINITY',
    first   => 'vip__infrastructure_alerting_mgmt_vip',
    second  => 'apache2-nagios',
    require => Pacemaker::Service['apache2-nagios'],
  }

  # Nagios resources for Pacemaker
  pacemaker::service { 'nagios3':
    primitive_type   => 'ocf-ns_nagios',
    parameters       => {
      'ns' => 'infrastructure_alerting',
    },
    complex_type     => 'clone',
    complex_metadata => {
      'migration-threshold' => '3',
      'failure-timeout'     => '120',
    },
    operations       => {
      'monitor' => {
        'interval' => '30',
        'timeout'  => '60'
      },
      'start'   => {
        'timeout' => '60'
      },
      'stop'    => {
        'timeout' => '60'
      },
    },
    prefix           => false,
    use_handler      => false,
    require          => [File['ocf-ns_nagios'], Exec['net.ipv4.ip_nonlocal_bind'], Class['lma_infra_alerting::nagios']],
  }

  pcmk_colocation { 'infrastructure_alerting_vip-with-nagios':
    ensure  => present,
    score   => 'INFINITY',
    first   => 'vip__infrastructure_alerting_mgmt_vip',
    second  => 'nagios3',
    require => Pacemaker::Service['nagios3'],
  }

  # The two VIPs must be colocated
  # This assumes VIPs are already created
  pcmk_colocation { 'ui_vip-with-wsgi_vip':
    ensure => present,
    score  => 'INFINITY',
    first  => 'vip__infrastructure_alerting_mgmt_vip',
    second => 'vip__infrastructure_alerting_ui',
  }
}

class { 'lma_infra_alerting::nagios::contact':
  send_to         => $send_to,
  send_from       => $send_from,
  smtp_host       => $smtp_host,
  smtp_auth       => $smtp_auth,
  smtp_user       => $smtp_user,
  smtp_password   => $smtp_password,
  notify_warning  => $notify_warning,
  notify_critical => $notify_critical,
  notify_recovery => $notify_recovery,
  notify_unknown  => $notify_unknown,
  require         => Class['lma_infra_alerting::nagios'],
}

if $lma_collector['node_cluster_roles'] {
  $node_cluster_roles = $lma_collector['node_cluster_roles']
} else {
  $node_cluster_roles = {}
}
if $lma_collector['node_cluster_alarms'] {
  $node_cluster_alarms = $lma_collector['node_cluster_alarms']
} else {
  $node_cluster_alarms = {}
}

$network_metadata  = hiera_hash('network_metadata')
class { 'lma_infra_alerting::nagios::hosts':
  hosts                  => values($network_metadata['nodes']),
  host_name_key          => 'name',
  network_role_key       => 'infrastructure_alerting',
  role_key               => 'node_roles',
  host_display_name_keys => ['name', 'user_node_name'],
  host_custom_vars_keys  => ['fqdn', 'node_roles'],
  node_cluster_roles     => $node_cluster_roles,
  node_cluster_alarms    => $node_cluster_alarms,
  require                => Class['lma_infra_alerting::nagios'],
}

$influxdb_nodes = get_nodes_hash_by_roles($network_metadata, ['influxdb_grafana', 'primary-influxdb_grafana'])
$es_kibana_nodes = get_nodes_hash_by_roles($network_metadata, ['elasticsearch_kibana', 'primary-elasticsearch_kibana'])

# Configure Grafana and InfluxDB checks
if ! empty($influxdb_nodes){
  $grafana_nodes_params = get_check_http_params($influxdb_nodes, 'influxdb_vip', 'Grafana')
  $grafana_defaults = {
    port                       => hiera('lma::infrastructure_alerting::grafana_port'),
    url                        => '/login',
    string_expected_in_content => 'grafana',
    service_description        => 'Grafana',
    require                    => Class['lma_infra_alerting::nagios::hosts'],
  }
  create_resources(lma_infra_alerting::nagios::check_http, $grafana_nodes_params, $grafana_defaults)

  $influxdb_nodes_params = get_check_http_params($influxdb_nodes, 'influxdb_vip', 'InfluxDB')
  $influxdb_defaults = {
    port                       => hiera('lma::infrastructure_alerting::influxdb_port'),
    url                        => '/ping',
    string_expected_in_status  => '204 No Content',
    string_expected_in_headers => 'X-Influxdb-Version',
    service_description        => 'InfluxDB',
    require                    => Class['lma_infra_alerting::nagios::hosts'],
  }
  create_resources(lma_infra_alerting::nagios::check_http, $influxdb_nodes_params, $influxdb_defaults)
}

# Configure Elasticsearch and Kibana checks
if ! empty($es_kibana_nodes){
  $kibana_nodes_params = get_check_http_params($es_kibana_nodes, 'elasticsearch', 'Kibana')
  $kibana_defaults = {
    port                       => hiera('lma::infrastructure_alerting::kibana_port'),
    url                        => '/',
    string_expected_in_content => 'kibana',
    service_description        => 'Kibana',
    require                    => Class[lma_infra_alerting::nagios::hosts],
  }
  create_resources(lma_infra_alerting::nagios::check_http, $kibana_nodes_params, $kibana_defaults)

  $es_nodes_params = get_check_http_params($es_kibana_nodes, 'elasticsearch', 'Elasticsearch')
  $es_defaults = {
    port                       => hiera('lma::infrastructure_alerting::es_port'),
    url                        => '/',
    string_expected_in_content => '"lucene_version"',
    service_description        => 'Elasticsearch',
    require                    => Class[lma_infra_alerting::nagios::hosts],
  }
  create_resources(lma_infra_alerting::nagios::check_http, $es_nodes_params, $es_defaults)
}
