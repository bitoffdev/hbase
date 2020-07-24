#
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# File passed to org.jruby.Main by bin/hbase.  Pollutes jirb with hbase imports
# and hbase  commands and then loads jirb.  Outputs a banner that tells user
# where to find help, shell version, and loads up a custom hirb.
#
# In noninteractive mode, runs commands from stdin until completion or an error.
# On success will exit with status 0, on any problem will exit non-zero. Callers
# should only rely on "not equal to 0", because the current error exit code of 1
# will likely be updated to diffentiate e.g. invalid commands, incorrect args,
# permissions, etc.

# TODO: Interrupt a table creation or a connection to a bad master.  Currently
# has to time out.  Below we've set down the retries for rpc and hbase but
# still can be annoying (And there seem to be times when we'll retry for
# ever regardless)
# TODO: Add support for listing and manipulating catalog tables, etc.
# TODO: Encoding; need to know how to go from ruby String to UTF-8 bytes

# Run the java magic include and import basic HBase types that will help ease
# hbase hacking.
include Java

# Some goodies for hirb. Should these be left up to the user's discretion?
require 'irb/completion'
require 'pathname'

# Add the directory names in hbase.jruby.sources commandline option
# to the ruby load path so I can load up my HBase ruby modules
sources = java.lang.System.getProperty('hbase.ruby.sources')
$LOAD_PATH.unshift Pathname.new(sources)

#
# FIXME: Switch args processing to getopt
#
# See if there are args for this shell. If any, read and then strip from ARGV
# so they don't go through to irb.  Output shell 'usage' if user types '--help'
cmdline_help = <<HERE # HERE document output as shell usage
Usage: shell [OPTIONS] [SCRIPTFILE [ARGUMENTS]]

 -d | --debug            Set DEBUG log levels.
 -h | --help             This help.
 -n | --noninteractive   Do not run within an IRB session and exit with non-zero
                         status on first error.
 -Dkey=value             Pass hbase-*.xml Configuration overrides. For example, to
                         use an alternate zookeeper ensemble, pass:
                           -Dhbase.zookeeper.quorum=zookeeper.example.org
                         For faster fail, pass the below and vary the values:
                           -Dhbase.client.retries.number=7
                           -Dhbase.ipc.client.connect.max.retries=3
HERE

# Takes configuration and an arg that is expected to be key=value format.
# If c is empty, creates one and returns it
def add_to_configuration(c, arg)
  kv = arg.split('=')
  kv.length == 2 || (raise "Expected parameter #{kv} in key=value format")
  c = org.apache.hadoop.hbase.HBaseConfiguration.create if c.nil?
  c.set(kv[0], kv[1])
  c
end

found = []
script2run = nil
log_level = org.apache.log4j.Level::ERROR
@shell_debug = false
interactive = true
_configuration = nil
D_ARG = '-D'.freeze
while (arg = ARGV.shift)
  if arg == '-h' || arg == '--help'
    puts cmdline_help
    exit
  elsif arg == D_ARG
    argValue = ARGV.shift || (raise "#{D_ARG} takes a 'key=value' parameter")
    _configuration = add_to_configuration(_configuration, argValue)
    found.push(arg)
    found.push(argValue)
  elsif arg.start_with? D_ARG
    _configuration = add_to_configuration(_configuration, arg[2..-1])
    found.push(arg)
  elsif arg == '-d' || arg == '--debug'
    log_level = org.apache.log4j.Level::DEBUG
    $fullBackTrace = true
    @shell_debug = true
    found.push(arg)
    puts 'Setting DEBUG log level...'
  elsif arg == '-n' || arg == '--noninteractive'
    interactive = false
    found.push(arg)
  elsif arg == '-r' || arg == '--return-values'
    warn '[INFO] the -r | --return-values option is ignored. we always behave '\
         'as though it was given.'
    found.push(arg)
  else
    # Presume it a script. Save it off for running later below
    # after we've set up some environment.
    script2run = arg
    found.push(arg)
    # Presume that any other args are meant for the script.
    break
  end
end

# Delete all processed args
found.each { |arg| ARGV.delete(arg) }
# Make sure debug flag gets back to IRB
ARGV.unshift('-d') if @shell_debug

# Set logging level to avoid verboseness
org.apache.log4j.Logger.getLogger('org.apache.zookeeper').setLevel(log_level)
org.apache.log4j.Logger.getLogger('org.apache.hadoop.hbase').setLevel(log_level)

# Require HBase now after setting log levels
require 'hbase_constants'

# Load hbase shell
require 'shell'

# Require formatter
require 'shell/formatter'

hbase = _configuration.nil? ? Hbase::Hbase.new : Hbase::Hbase.new(_configuration)
shl = Shell::Shell.new(hbase, true)
shl.debug = @shell_debug
hbase_workspace = shl.create_workspace

# Debugging method
def debug
  if @shell_debug
    @shell_debug = false
    conf.back_trace_limit = 0
    log_level = org.apache.log4j.Level::ERROR
  else
    @shell_debug = true
    conf.back_trace_limit = 100
    log_level = org.apache.log4j.Level::DEBUG
  end
  org.apache.log4j.Logger.getLogger('org.apache.zookeeper').setLevel(log_level)
  org.apache.log4j.Logger.getLogger('org.apache.hadoop.hbase').setLevel(log_level)
  debug?
end

def debug?
  puts "Debug mode is #{@shell_debug ? 'ON' : 'OFF'}\n\n"
  nil
end

require 'irb/hirb'

# If script2run, try running it.  If we're in interactive mode, will go on to run the shell unless
# script calls 'exit' or 'exit 0' or 'exit errcode'.
shl.eval_io(File.new(script2run)) if script2run

# If we are not running interactively, evaluate standard input
shl.eval_io(STDIN) unless interactive

if interactive
  # Output a banner message that tells users where to go for help
  shl.print_banner

  require 'irb'
  require 'irb/ext/change-ws'
  require 'irb/hirb'

  module IRB
    # Override of the default IRB.start
    def self.start(ap_path = nil)
      $0 = File.basename(ap_path, '.rb') if ap_path

      IRB.setup(ap_path)
      @CONF[:IRB_NAME] = 'hbase'
      @CONF[:AP_NAME] = 'hbase'
      @CONF[:BACK_TRACE_LIMIT] = 0 unless $fullBackTrace

      hirb = if @CONF[:SCRIPT]
               HIRB.new(nil, @CONF[:SCRIPT])
             else
               HIRB.new
             end

      hbase_workspace = TOPLEVEL_BINDING.local_variable_get :hbase_workspace
      hirb.context.change_workspace hbase_workspace

      @CONF[:IRB_RC].call(hirb.context) if @CONF[:IRB_RC]
      # Storing our current HBase IRB Context as the main context is imperative for several reasons,
      # including auto-completion.
      @CONF[:MAIN_CONTEXT] = hirb.context

      catch(:IRB_EXIT) do
        hirb.eval_input
      end
    end
  end

  IRB.start
end
