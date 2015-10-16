require 'cfndsl'

CloudFormation {

  # Template metadata
  AWSTemplateFormatVersion "2010-09-09"
  Description "ciinabox - ECS Service ELBs v#{ciinabox_version}"

  # Parameters
  Parameter("ECSCluster"){ Type 'String' }
  Parameter("SubnetPublicA"){ Type 'String' }
  Parameter("SubnetPublicB"){ Type 'String' }
  Parameter("ECSSubnetPrivateA"){ Type 'String' }
  Parameter("ECSSubnetPrivateB"){ Type 'String' }
  Parameter("SecurityGroupBackplane"){ Type 'String' }
  Parameter("SecurityGroupOps"){ Type 'String' }
  Parameter("SecurityGroupDev"){ Type 'String' }

  Resource("ECSRole") {
    Type 'AWS::IAM::Role'
    Property('AssumeRolePolicyDocument', {
      Statement: [
        Effect: 'Allow',
        Principal: { Service: [ 'ecs.amazonaws.com' ] },
        Action: [ 'sts:AssumeRole' ]
      ]
    })
    Property('Path','/')
    Property('Policies', [
      {
        PolicyName: 'read-only',
        PolicyDocument: {
          Statement: [
            {
              Effect: 'Allow',
              Action: [ 'ec2:Describe*', 's3:Get*', 's3:List*'],
              Resource: '*'
            }
          ]
        }
      },
      {
        PolicyName: 's3-write',
        PolicyDocument: {
          Statement: [
            {
              Effect: 'Allow',
              Action: [ 's3:PutObject', 's3:PutObject*' ],
              Resource: '*'
            }
          ]
        }
      },
      {
        PolicyName: 'ecsServiceRole',
        PolicyDocument: {
          Statement: [
            {
              Effect: 'Allow',
              Action: [
                "ecs:CreateCluster",
                "ecs:DeregisterContainerInstance",
                "ecs:DiscoverPollEndpoint",
                "ecs:Poll",
                "ecs:RegisterContainerInstance",
                "ecs:StartTelemetrySession",
                "ecs:Submit*",
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:Describe*",
                "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
                "elasticloadbalancing:Describe*",
                "elasticloadbalancing:RegisterInstancesWithLoadBalancer"
              ],
              Resource: '*'
            }
          ]
        }
      },
      {
        PolicyName: 'packer',
        PolicyDocument: {
          Statement: [
            {
              Effect: 'Allow',
              Action: [
                'ec2:AttachVolume',
                'ec2:CreateVolume',
                'ec2:DeleteVolume',
                'ec2:CreateKeypair',
                'ec2:DeleteKeypair',
                'ec2:CreateSecurityGroup',
                'ec2:DeleteSecurityGroup',
                'ec2:AuthorizeSecurityGroupIngress',
                'ec2:CreateImage',
                'ec2:RunInstances',
                'ec2:TerminateInstances',
                'ec2:StopInstances',
                'ec2:DescribeVolumes',
                'ec2:DetachVolume',
                'ec2:DescribeInstances',
                'ec2:CreateSnapshot',
                'ec2:DeleteSnapshot',
                'ec2:DescribeSnapshots',
                'ec2:DescribeImages',
                'ec2:RegisterImage',
                'ec2:CreateTags',
                'ec2:ModifyImageAttribute'
              ],
              Resource: '*'
            }
          ]
        }
      }
    ])
  }

  services.each do |name|
    name.each do |service_name, service|

      listeners = []
      ssl_cert_id = service['ssl_cert_id'] || default_ssl_cert_id
      listeners << { LoadBalancerPort: '80', InstancePort: service['service_port'], Protocol: 'HTTP' }
      listeners << { LoadBalancerPort: '443', InstancePort: service['service_port'], Protocol: 'HTTPS', SSLCertificateId: ssl_cert_id  } if service['https_enabled']

      Resource("#{service_name}ELB2") {
        Type 'AWS::ElasticLoadBalancing::LoadBalancer'
        Property('Listeners', listeners)
        Property('HealthCheck', {
          Target: "TCP:#{service['service_port']}",
          HealthyThreshold: '3',
          UnhealthyThreshold: '2',
          Interval: '15',
          Timeout: '5'
        })
        Property('CrossZone',true)
        Property('SecurityGroups',[
          Ref('SecurityGroupBackplane'),
          Ref('SecurityGroupOps'),
          Ref('SecurityGroupDev')
        ])
        Property('Subnets',[
          Ref('SubnetPublicA'),Ref('SubnetPublicB')
        ])
      }

      subdomain_prefix = service['subdomain_prefix'] || service_name

      Resource("#{service_name}DNS") {
        Type 'AWS::Route53::RecordSet'
        Property('HostedZoneName', FnJoin('', [ dns_domain, '.']))
        Property('Name', FnJoin('', [subdomain_prefix, '.', dns_domain, '.']))
        Property('Type','A')
        Property('AliasTarget', {
          'DNSName' => FnGetAtt("#{service_name}ELB2",'DNSName'),
          'HostedZoneId' => FnGetAtt("#{service_name}ELB2",'CanonicalHostedZoneNameID')
        })
      }

      # ECS Task Def and Service  Stack
      Resource("#{service_name}Stack") {
        Type 'AWS::CloudFormation::Stack'
        Property('TemplateURL', FnJoin('', ['https://s3-', Ref('AWS::Region'), ".amazonaws.com/#{source_bucket}/ciinabox/#{ciinabox_version}/services/#{service_name}.json"]))
        Property('TimeoutInMinutes', 5)
        Property('Parameters',{
          ECSCluster: Ref('ECSCluster'),
          ECSRole: Ref('ECSRole'),
          ServiceELB: Ref("#{service_name}ELB2")
        })
      }

    end
  end
}