#!/usr/bin/env ruby
require 'rubygems'
require 'micro-optparse'
require 'rest-client'
require 'json'
require 'base64'

# Nagios Exit codes
VERSION = '0.6'
NAGIOS_UNKNOWN = 3
NAGIOS_CRITICAL = 2
NAGIOS_OK = 0
NAGIOS_WARNING = 1

# Items per page for search queries
FOREMAN_PER_PAGE = 1000
# http://stackoverflow.com/a/8571649
BASE64_REGEX = Regexp.new('^([A-Za-z0-9+\/]{4})*([A-Za-z0-9+\/]{4}|[A-Za-z0-9+\/]{3}=|[A-Za-z0-9+\/]{2}==)$')

perfdata = ''
exit_code = NAGIOS_UNKNOWN
exit_string = ''

@options = Parser.new do |p|
  p.banner = "Foreman status checks for Nagios/Icinga v#{VERSION}"
  p.version = VERSION
  p.option :user, 'Foreman API user', :short => 'u', :default => ''
  p.option :password, 'Foreman API password', :short => 'p', :default => ''
  p.option :endpoint, 'Foreman API endpoint URL', :short => 'H', :default => ''
  p.option :verbose, 'Enable verbose output for debugging', :short => 'v', :default => false
  p.option :argument, 'Check command argument', :short => 'a', :default => '', :optional => true
  p.option :base64, 'Assume base64 encoded argument', :short => 'B', :default => false
  p.option :command, 'Check command. One of "dashboard", "search", "fact". "search" will search hosts for argument, fact will search "facts"', :short => 'C', :default => 'dashboard', :value_in_set => ['dashboard', 'search', 'fact']
  p.option :warning, 'Warning value', :short => 'w', :default => 1
  p.option :critical, 'Critical value', :short => 'c', :default => 5
  p.option :silent, 'Suppress performance data output', :short => 'P', :default => false
  p.option :encode64, 'Helper: Encode value from STDIN to base64', :default => false
end.process!

if @options[:encode64]
  printf 'Enter sting and press <ENTER>: '
  puts Base64.encode64(gets.chomp).tr("\n", '')
  exit NAGIOS_OK
end

if @options[:endpoint].empty? || @options[:user].empty? || @options[:password].empty? || @options[:warning].to_f >= @options[:critical].to_f
  puts 'Argument error: Options "--user", "--password" and "--endpoint" must be supplied. Warning value must be lower then critical'
  exit NAGIOS_UNKNOWN
end

if @options[:verbose]
  @options.each do |opt|
    puts "Got option #{opt}"
  end
end

@argument = @options[:argument]
@argument = Base64.decode64(@options[:argument]) if @options[:base64] && @options[:argument].to_s =~ BASE64_REGEX
puts "Using search string: '#{@argument}'" if @options[:verbose]

@foreman = RestClient::Resource.new @options[:endpoint], @options[:user], @options[:password]

case @options[:command]
when /dashboard/i
  dash = JSON.parse(@foreman['/dashboard'].get, :symbolize_names => true)
  if dash[:bad_hosts] < @options[:warning].to_f
    exit_string = 'Foreman Dashbord: OK'
    exit_code = NAGIOS_OK
  elsif dash[:bad_hosts] >= @options[:warning].to_f && dash[:bad_hosts] < @options[:critical].to_f
    exit_string = "Foreman Dashbord: WARNING, bad hosts: #{dash[:bad_hosts]}"
    exit_code = NAGIOS_WARNING
  elsif dash[:bad_hosts] >= @options[:critical].to_f
    exit_string = "Foreman Dashbord: CRITICAL, bad hosts: #{dash[:bad_hosts]}"
    exit_code = NAGIOS_CRITICAL
  else 
    exit_string = 'Foreman Dashbord: UNKNOWN'
    exit_code = NAGIOS_UNKNOWN
  end
  unless exit_code == NAGIOS_UNKNOWN
    perfdata = '|'
    max = dash[:total_hosts]
    dash.each do |item|
      next if item[0] == :glossary
      perfdata << "#{item[0]}=#{item[1]};;;0;#{max} " unless item[0] == :bad_hosts 
      perfdata << "#{item[0]}=#{item[1]};#{@options[:warning].to_f};#{@options[:critical].to_f};0;#{max} " if item[0] == :bad_hosts
    end
  end
when /search/i
  dash = JSON.parse(@foreman['/hosts'].get(:params => {:search => @argument, :per_page => FOREMAN_PER_PAGE }), :symbolize_names => true)
  puts dash if @options[:verbose]
  puts dash[:subtotal] if @options[:verbose]
  bad_hosts = ''
  if dash[:subtotal] > 0
    dash[:results].each do |host|
      puts host[:name] if @options[:verbose]
      bad_hosts << "#{host[:name]}, "
    end
    bad_hosts.chomp!(', ')
  end
  if dash[:subtotal] < @options[:critical].to_f
    exit_string = 'Foreman Seach: OK'
    exit_code = NAGIOS_OK
  elsif dash[:subtotal] >= @options[:critical].to_f
    exit_string = "Foreman Search: CRITICAL, bad hosts: #{bad_hosts}"
    exit_code = NAGIOS_CRITICAL
  else 
    exit_string = 'Foreman Search: UNKNOWN'
    exit_code = NAGIOS_UNKNOWN
  end 
  unless exit_code == NAGIOS_UNKNOWN
    perfdata = "|found=#{dash[:subtotal]};;#{@options[:critical].to_f};0"
  end
when /fact/i
  facts_warning = []
  facts_critical = []
  warning_hosts = ''
  critical_hosts = ''
  @factname = ''
  dash = JSON.parse(@foreman['fact_values'].get(:params => {:search => @argument, :per_page => FOREMAN_PER_PAGE }), :symbolize_names => true)
  dash[:results].each do |host, result| 
    puts "Item #{host}:" if @options[:verbose]
    result.each do |key, value|
      @factname = " '#{key.to_s}'" if @factname.empty?
      checkval = value.to_f
      puts " -> #{checkval}" if @options[:verbose]
      if checkval < @options[:warning].to_f
        next
      elsif checkval >= @options[:warning].to_f && checkval < @options[:critical].to_f
        facts_warning << host.to_s
        warning_hosts << "#{host},"
      elsif checkval >= @options[:critical].to_f
        facts_critical << host.to_s
        critical_hosts << "#{host},"
      end
    end
  end
  info_string = ''
  info_string << "List Warning: (#{warning_hosts.chomp(',')}) " unless facts_warning.empty?
  info_string << "List Critical: (#{critical_hosts.chomp(',')}) " unless facts_critical.empty?
  if facts_critical.length > 0
    exit_string = "Foreman Fact#{@factname}: CRITICAL, #{info_string}"
    exit_code = NAGIOS_CRITICAL
  elsif facts_warning.length > 0 && facts_critical.length == 0
    exit_string = "Foreman Fact#{@factname}: WARNING, #{info_string}"
    exit_code = NAGIOS_WARNING
  elsif facts_warning.length == 0 && facts_critical.length == 0
    exit_string = "Foreman Fact#{@factname}: OK"
    exit_code = NAGIOS_OK
  else 
   exit_string = 'Foreman Fact: UNKNOWN'
   exit_code = NAGIOS_UNKNOWN
  end 
  unless exit_code == NAGIOS_UNKNOWN
    perfdata = "|ok_count=#{dash[:results].length - facts_warning.length - facts_critical.length};;;0;#{dash[:results].length} warning_count=#{facts_warning.length};;;0;#{dash[:results].length} critical_count=#{facts_critical.length};;;0;#{dash[:results].length}"
  end
end

puts "#{exit_string}#{perfdata.chomp(';') unless @options[:silent]}"
exit exit_code
