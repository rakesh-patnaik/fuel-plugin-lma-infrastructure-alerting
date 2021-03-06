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
# Configure virtual Nagios hosts for monitoring the clusters of global services
# and nodes.
#
class lma_infra_alerting::nagios::vhost (
  $openstack_management_vip = undef,
  $openstack_deployment_name = '',
  $global_clusters = [],
  $node_clusters = [],
) inherits lma_infra_alerting::params {

  validate_array($global_clusters, $node_clusters)

  $vhostname_global = join([
    $lma_infra_alerting::params::nagios_global_vhostname_prefix,
    '-env', $openstack_deployment_name], '')
  $vhostname_node = join([
    $lma_infra_alerting::params::nagios_node_vhostname_prefix,
    '-env', $openstack_deployment_name], '')

  if ! empty($global_clusters) {
    # Configure the virtual host for the global clusters
    lma_infra_alerting::nagios::vhost_cluster_status{ 'global':
      ip                    => $openstack_management_vip,
      hostname              => $vhostname_global,
      services              => $global_clusters,
      notifications_enabled => 1,
    }
  }

  if ! empty($node_clusters) {
    # Configure the virtual host for the node clusters
    lma_infra_alerting::nagios::vhost_cluster_status{ 'nodes':
      ip                    => $openstack_management_vip,
      hostname              => $vhostname_node,
      services              => $node_clusters,
      notifications_enabled => 0,
    }
  }
}
