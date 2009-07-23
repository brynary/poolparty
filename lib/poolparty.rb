$LOAD_PATH.unshift(File.dirname(__FILE__))

t=Time.now

# Load system gems
%w(rubygems logger erb net/ssh).each do |lib|
  require lib
end

# Add all vendor gems to the load paths
Dir[File.dirname(__FILE__)+"/../vendor/gems/*"].each {|lib| $LOAD_PATH.unshift(File.expand_path("#{lib}/lib")) }

# Load local gems
%w(dslify parenting json).each do |dep|
  require dep
end

# Require the poolparty error so we can use it ubiquitously
require "poolparty/pool_party_error"

# Core object overloads
%w( object
    module
    string
    integer
    array
    hash
    symbol
    proc
    time).each do |lib|
  require "core/#{lib}"
end

# Features
%w(callbacks pinger searchable_paths).each do |lib|
  require "mixins/#{lib}"
end

require "keypair"

# PoolParty core
$LOAD_PATH.unshift(File.dirname(__FILE__)/"poolparty")
%w( default pool_party_log base dsl_base cloud 
    installer
    pool resource plugin ).each do |lib|
  require "poolparty/#{lib}"
end

require 'cloud_providers'

# dependency_resolvers
require "dependency_resolver"

require "provision/bootstrapper"

vputs "PoolParty core loadtime: #{Time.now-t}"