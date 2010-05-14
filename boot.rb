#!/usr/bin/env ruby

require 'socket'

# change to the directory this file lives in
Dir.chdir(File.dirname(__FILE__))

def helpdump
	STDERR.puts "usage: #{$0} [-c cookiename] [-s shortname | -n longname] [-b bootfile] [-f configfile] [-d] [-r] [-q]"
	STDERR.puts
	STDERR.puts "  -c defaults to \"ClueCon\" or, if a .erlang.cookie file is in the directory, the contents of that."
	STDERR.puts "  -s and -n override each other.  Defaults to \"-s testme\"."
	STDERR.puts "  -b only needs the file name, ebin is assumed.  Defaults to \"cpx-rel-0.1\"."
	STDERR.puts "  -f defaults to \"single\"."
	STDERR.puts "  -d uses the debug compile."
	STDERR.puts "  -r to add -run reloader to the erl command line flags."
	STDERR.puts "  -q to run the system detached; good for daemonizing."
	STDERR.puts ""
	STDERR.puts "If you have not yet run rake (or rake test if you are using"
	STDERR.puts "-d), erl will fail to start.  If the config file does not"
	STDERR.puts "exist, a default config is put in it's place.  Feel free"
	STDERR.puts "to edit it."
	exit
end

if File.exists?(".erlang.cookie")
	$cookie = File.read(".erlang.cookie").chomp
else
	$cookie = "ClueCon"
end

$ebin = 'ebin/'
$nametype = '-sname'
$name = 'testme'
$conf = 'single'
$boot = 'cpx-rel-0.1'
$reloader = ''
$daemon = ''

while true do
	case ARGV[0]
		when '--help'
			helpdump
			exit(0)

		when '-c'
			ARGV.shift
			$cookie = ARGV.shift
		
		when '-s'
			ARGV.shift
			$nametype = "-sname"
			$name = ARGV.shift

		when '-n'
			ARGV.shift
			$nametype = "-name"
			$name = ARGV.shift

		when '-b'
			ARGV.shift
			$boot = ARGV.shift

		when '-f'
			ARGV.shift
			$conf = ARGV.shift

		when '-d'
			ARGV.shift
			$ebin = 'debug_ebin/'
			
		when '-r'
			ARGV.shift
			$reloader = ' -run reloader'

		when '-q'
			ARGV.shift
			$daemon = ' -detached'

		else
			break
	end
end

unless File.exists?(File.join('ebin', $boot + '.boot'))
	STDERR.puts "Boot file \"#{File.join('ebin', $boot + '.boot')}\" missing, did you run `rake' first?"
	exit(1)
end

if ! File.exists?($conf + ".config")
	f = File.new($conf + ".config", "w+")

	hostname = Socket.gethostname
	if $nametype == "-sname"
		hostname = hostname.split('.')[0]
	end
	node = $name + "@" + hostname

	f.puts "%% This file was generated by boot.rb."
	f.puts "%% If you are comfortable editing erlang application configuration scripts"
	f.puts "%% there is no harm in editing the file."
	f.puts "[{cpx, ["
	f.puts "	{nodes, ['#{node}']},"
	f.puts "	{console_loglevel, info},"
	f.puts "	{logfiles, [{\"full.log\", debug}, {\"console.log\", info}]}"
	f.puts "]},"
	f.puts "{sasl, ["
	f.puts "	{errlog_type, error} % disable SASL progress reports"
	f.puts "]}]."
	f.close
end

execStr = "erl +K true -pa #{$ebin} -setcookie #{$cookie} #{$nametype} #{$name} -config #{$conf} -boot ebin/#{$boot} #{$reloader}#{$daemon}"
#puts execStr
exec execStr
