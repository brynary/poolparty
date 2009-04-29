=begin rdoc
  EC2 Remoter Base
  
  This serves as the basis for running PoolParty on Amazon's ec2 cloud.
=end
require "date"
require "#{::File.dirname(__FILE__)}/ec2_response_object"

begin
  require 'EC2'
rescue LoadError
  puts <<-EOM
Error: In order to use ec2, you need to install the amazon-ec2 gem

Ec2 is the default remoter base for PoolParty. If you intend on using
a different remoter base, specify it with:

using :remoter_name

in your config file, otherwise, to continue install grempe-amazon-ec2 with

sudo gem install grempe-amazon-ec2 --source http://gems.github.com
EOM
end
  
class String
  def convert_from_ec2_to_ip
    self.gsub(/.compute-1.amazonaws.com*/, '').gsub(/ec2-/, '').gsub(/-/, '.')
  end
  def parse_datetime
    DateTime.parse( self.chomp ) rescue self
  end
end
  
module PoolParty    
  module Remote
    class Ec2 < Remote::RemoterBase
      
      default_options({
        :image_id => 'ami-bf5eb9d6',
        # :key_name => ::File.basename(keypair.is_a?(String) ? keypair : keypair.full_filepath),
        :instance_type => 'm1.small', # or 'm1.large', 'm1.xlarge', 'c1.medium', or 'c1.xlarge'
        :addressing_type => "public",
        :availabilty_zone => "us-east-1a",
        :security_group => ["default"]
        })
      
      # Requires a hash of options
      def self.launch_new_instance!(parent_cloud, o)
        new(parent_cloud, o).launch_new_instance!
      end
      
      # TODO: Fix the key_name issue
      # Start a new instance with the given options
      def launch_new_instance!(o={})
        raise "You must pass a keypair to launch an instance, or else you will not be able to login. options = #{o.inspect}" if !cloud.keypair
        o.merge!( options ).merge!(:key_name=>keypair.basename)
        instance = ec2(o).run_instances(o)
        begin
          h = EC2ResponseObject.get_hash_from_response(instance.instancesSet.item.first)
          #h = instance.instancesSet.item.first
        rescue Exception => e
          h = EC2ResponseObject.get_hash_from_response(instance) rescue instance
          # h = instance
        end
        h
      end
      # Terminate an instance by id
      def terminate_instance!(o={})
        ec2(o).terminate_instances(:instance_id => o[:instance_id])
      end
      # Describe an instance's status
      def describe_instance(o={})
        return describe_instances.first if o[:instance_id].nil?
        describe_instances.detect {|a| a[:name] == o[:instance_id] || a[:ip] == o[:instance_id] || a[:instance_id] == o[:instance_id] }
      end
      def describe_instances(o={})
        id = 0
        get_instances_description(options.merge(o)).each_with_index do |h,i|          
          if h[:status] == "running"
            inst_name = id == 0 ? "master" : "node#{id}"
            id += 1
          else
            inst_name = "#{h[:status]}_node#{i}"
          end
          h.merge!({
            :name => inst_name,
            :hostname => h[:ip],
            :ip => h[:ip].convert_from_ec2_to_ip,
            :index => i,  #TODO MF get the instance id from the aws result instead
            :launching_time => (h[:launching_time])
          })
        end.compact.sort {|a,b| a[:index] <=> b[:index] }
      end
      
      # ===================================
      # = Ec2 Specific methods below here =
      # ===================================
      
      # return or create a new base EC2 connection object that will actually connect to ec2
      def ec2(o={})
        @ec2 ||= EC2::Base.new( :access_key_id => o[:access_key], 
                                :secret_access_key => o[:secret_access_key]
                              )
      end
      def self.ec2(o)
        @ec2 ||= self.class.ec2(o)
      end
      
      # Get the ec2 description for the response in a hash format
      def get_instances_description(o={})
        #TODO: only use keypair.full_filepath
        key_hash = {:keypair => ::File.basename(keypair.is_a?(String) ? keypair : keypair.full_filepath)}
        EC2ResponseObject.get_descriptions(ec2(o).describe_instances).select_with_hash(key_hash)
      end
      def get_descriptions(o={})
        self.class.get_descriptions(o)
      end
      
      def keypair
        cloud.keypair
      end
      
      # Class method helpers
      def aws_keys
        unless @access_key && @secret_access_key          
          aws_keys = {}
          aws_keys = YAML::load( File.open('/etc/poolparty/aws_keys.yml') ) rescue 'No aws_keys.yml file.   Will try to use enviornment variables'
          @access_key ||= aws_keys[:access_key] || ENV['AMAZON_ACCESS_KEY_ID'] || ENV['AWS_ACCESS_KEY']
          @secret_access_key ||= aws_keys[:secret_access_key] || ENV['AMAZON_SECRET_ACCESS_KEY'] || ENV['AWS_SECRET_ACCESS_KEY']
        end
        [@access_key, @secret_access_key]
      end
      
      def after_launch_instance(inst)
        if inst
          associate_address(inst)
        end
      end
    
      # Attach a volume to the instance
      # DEPRECATE this relies on master.  master will be removed in next major release.  This method will be in ec2_remote_instance instead, or require an instance id
      def attach_volume(instance=nil)
        if ebs_volume_id
          vputs "Attaching volume #{ebs_volume_id} to the master at #{ebs_volume_device}"
          instance = master        
          ec2.attach_volume(:volume_id => ebs_volume_id, :instance_id => instance.instance_id, :device => ebs_volume_device) if ebs_volume_id && ebs_volume_mount_point
        end
      end
      
      # Associate an address with the instance using ec2
      # Get the next_unused_elastic_ip
      # and if there is one, associate the instance to the 
      # public ip
      def associate_address(instance=nil)
        if ip = next_unused_elastic_ip
          vputs "Associating #{instance.instance_id} with #{ip}"
          ec2.associate_address(:instance_id => instance.instance_id, :public_ip => ip)
        end
      end
      
      # Get the next usable elastic ip
      # First, get the list of addresses from ec2 that the client
      # has access to, then select only the ones that are not associated
      # with an instance.
      # If the cloud has set elastic_ips to use, then, using the 
      # intersection of the unused ips and those, find the first one available
      # and return that, otherwise, return the first elastic ip available
      def next_unused_elastic_ip
        # [{"instanceId"=>nil, "publicIp"=>"174.129.212.93"}, {"instanceId"=>nil, "publicIp"=>"174.129.212.94"}]
        if addressesSet = ec2(options).describe_addresses["addressesSet"]
          begin
            empty_addresses = addressesSet["item"].select {|i| i["instanceId"].nil? }
            ips = empty_addresses.map {|addr| addr["publicIp"]}
            if cloud.elastic_ips?
              ips_to_use = cloud.elastic_ips & ips
              ips_to_use.first
            else
              ips.first
            end
          rescue Exception => e
            puts "Error: #{e}"
            nil
          end          
        end
      end

      # Help create a keypair for the cloud
      # This is a helper to create the keypair and add them to the cloud for you
      def create_keypair
        return false unless keypair
        unless ::File.exists?( new_keypair_path )
          FileUtils.mkdir_p ::File.dirname( new_keypair_path )
          vputs "Creating keypair: #{keypair} in #{new_keypair_path}"
          Kernel.system "ec2-add-keypair #{keypair} > #{new_keypair_path} && chmod 600 #{new_keypair_path}"
        end
      end
    
      # wrapper for remote base to perform a snapshot backup for the ebs volume
      def create_snapshot
        return nil if ebs_volume_id.nil?
        ec2.create_snapshot(:volume_id => ebs_volume_id)
      end
    
      def has_cert_and_key?
        pub_key && private_key
      end
      # The keys are used only for puppet certificates
      # and are only used for EC2.
      # Public key 
      def pub_key
        @pub_key ||= ENV["EC2_CERT"] ? ENV["EC2_CERT"] : nil
      end
      # Private key
      def private_key
        @private_key ||= ENV["EC2_PRIVATE_KEY"] ? ENV["EC2_PRIVATE_KEY"] : nil
      end
    
      def custom_minimum_runnable_options
        [:ami, :availabilty_zone, :security_group]
      end

      # Hook
      #TODO#: Change this so they match with the cap tasks
      def custom_install_tasks_for(o)        
        [
          # "if [ -z $(grep -v '#' /etc/hosts | grep '#{o.name}') ]; then echo \"$(curl http://169.254.169.254/latest/meta-data/public-ipv4) #{o.name}\" >> /etc/hosts; fi",
          "if [ -z \"$(grep -v '#' /etc/hosts | grep '#{o.name}')\" ]; then echo '127.0.0.1 #{o.name}' >> /etc/hosts; fi",
          "hostname #{o.name}",
          "echo #{o.name} > /etc/hostname"
        ]
      end
    
      def after_install_tasks_for(o)
        [
          # "cd /var/poolparty && wget http://rubyforge.org/frs/download.php/43666/amazon-ec2-0.3.1.gem -O amazon-ec2.gem 2>&1",
          # "/usr/bin/gem install --no-ri --no-rdoc amazon-ec2.gem 2>&1"
        ]
      end

      def custom_configure_tasks_for(o)
        [
        ]
      end

      def reset_base!
        @describe_instances = @cached_descriptions = nil
      end      
    end
        
  end
end