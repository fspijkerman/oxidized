module Oxidized
  require 'net/telnet'
  require 'oxidized/input/cli'
  class Telnet < Input
    RescueFail = {}
    include CLI
    attr_reader :telnet

    def connect node
      @node    = node
      @timeout = CFG.timeout
      @node.model.cfg['telnet'].each { |cb| instance_exec(&cb) }
      @telnet  = Net::Telnet.new 'Host' => @node.ip, 'Waittime' => @timeout,
                                 'Model' => @node.model
      expect username
      @telnet.puts @node.auth[:username]
      expect password
      @telnet.puts @node.auth[:password]
      expect @node.prompt
    end

    def cmd cmd, expect=@node.prompt
      Log.debug "Telnet: #{cmd} @#{@node.name}"
      args = { 'String' => cmd }
      args.merge!({ 'Match' => expect, 'Timeout' => @timeout }) if expect
      @telnet.cmd args
    end

    def send data
      @telnet.write data
    end

    def output
      @telnet.output
    end

    private

    def expect re
      @telnet.waitfor 'Match' => re, 'Timeout' => @timeout
    end

    def disconnect
      begin
        disconnect_cli
        @telnet.close
      rescue Errno::ECONNRESET
      end
    end

  end
end


class Net::Telnet
  ## FIXME: we just need 'line = model.expects line' to handle pager
  ## how to do this, without redefining the whole damn thing
  ## FIXME: we also need output (not sure I'm going to support this)
  attr_reader :output
  def waitfor(options) # :yield: recvdata
    time_out = @options["Timeout"]
    waittime = @options["Waittime"]
    fail_eof = @options["FailEOF"]
    model    = @options["Model"]

    if options.kind_of?(Hash)
      prompt   = if options.has_key?("Match")
                   options["Match"]
                 elsif options.has_key?("Prompt")
                   options["Prompt"]
                 elsif options.has_key?("String")
                   Regexp.new( Regexp.quote(options["String"]) )
                 end
      time_out = options["Timeout"]  if options.has_key?("Timeout")
      waittime = options["Waittime"] if options.has_key?("Waittime")
      fail_eof = options["FailEOF"]  if options.has_key?("FailEOF")
    else
      prompt = options
    end

    if time_out == false
      time_out = nil
    end

    line = ''
    buf = ''
    rest = ''
    until(prompt === line and not IO::select([@sock], nil, nil, waittime))
      unless IO::select([@sock], nil, nil, time_out)
        raise TimeoutError, "timed out while waiting for more data"
      end
      begin
        c = @sock.readpartial(1024 * 1024)
        @output = c
        @dumplog.log_dump('<', c) if @options.has_key?("Dump_log")
        if @options["Telnetmode"]
          c = rest + c
          if Integer(c.rindex(/#{IAC}#{SE}/no) || 0) <
             Integer(c.rindex(/#{IAC}#{SB}/no) || 0)
            buf = preprocess(c[0 ... c.rindex(/#{IAC}#{SB}/no)])
            rest = c[c.rindex(/#{IAC}#{SB}/no) .. -1]
          elsif pt = c.rindex(/#{IAC}[^#{IAC}#{AO}#{AYT}#{DM}#{IP}#{NOP}]?\z/no) ||
                     c.rindex(/\r\z/no)
            buf = preprocess(c[0 ... pt])
            rest = c[pt .. -1]
          else
            buf = preprocess(c)
            rest = ''
          end
       else
         # Not Telnetmode.
         #
         # We cannot use preprocess() on this data, because that
         # method makes some Telnetmode-specific assumptions.
         buf = rest + c
         rest = ''
         unless @options["Binmode"]
           if pt = buf.rindex(/\r\z/no)
             buf = buf[0 ... pt]
             rest = buf[pt .. -1]
           end
           buf.gsub!(/#{EOL}/no, "\n")
         end
        end
        @log.print(buf) if @options.has_key?("Output_log")
        line += buf
        line = model.expects line
        line = yield line if block_given?
        yield buf if block_given?
      rescue EOFError # End of file reached
        raise if fail_eof
        if line == ''
          line = nil
          yield nil if block_given?
        end
        break
      end
    end
    line
  end
end
