# Benchmark Class for SystemTap
# Copyright (C) 2006 Red Hat Inc.
#
# This file is part of systemtap, and is free software.  You can
# redistribute it and/or modify it under the terms of the GNU General
# Public License (GPL); either version 2, or (at your option) any
# later version.

# Where to find laptop frequency files
MAXFILE = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq"
MINFILE = "/sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq"

# more constants
PROCFS = 1
RELAYFS= 2

at_exit {Bench.done}

class Bench
  def initialize(desc)
    @desc = desc
    @code = nil
    @file = nil
    @trans = 1
    @failures = []
    @results = []
    if @@printed_header == 0
      print_header
    end
    if @@staprun.nil?
      for path in ['/usr/bin/staprun', '/usr/local/bin/staprun'] 
	if File.exist?(path)
	  @@staprun = path
	  break
	end
      end
      # now do make
      `make`
      if $? != 0 || !File.exist?('itest')
	puts "ERROR: Compiling itest failed\n"
	exit
      end
    end
    if @@runtime.nil?
      for path in ['/usr/share/systemtap/runtime', '/usr/local/share/systemtap/runtime'] 
	if File.exist?(path)
	  @@runtime = path
	  break
	end
      end
    end
    Signal.trap("INT") do
      cleanup
      exit
    end
  end

  attr_writer :code, :file, :trans
  attr_reader :failures, :results

  def run
    compile
    @results = []
    @failures = []
    @@num_threads.each do |threads|
      load
      sum=0
      threads.times {|cpu| fork {exec "./itest #{threads} > #{@dir}/bench#{cpu}"}}
      threads.times {Process.waitpid(-1)}	# wait for itest(s) to exit
      `sudo killall -HUP staprun`
      Process.wait	# wait for staprun to exit
      threads.times {|x| sum = sum + `cat #{@dir}/bench#{x}`.split[0].to_i - @@ftime}
      @results[threads] = sum / (threads * threads)
      File.open("#{@dir}/xxx.out") do |file|
	file.each_line do |line| 
	  @failures[threads] = line.match(/were ([\d]*)/)[1]
	end
      end
    end
    cleanup
  end

  def print
    if @results
      if self.kind_of? Stapbench
	printf("S")
      else
	printf("R")
      end
      if @trans == RELAYFS
	printf("*")
      else
	printf(" ")
      end
      printf(": %-20s", @desc)
      @@num_threads.each {|thread| printf("\t%5d",@results[thread])}
      printf("\n")
      @@num_threads.each do |thread|
	printf("WARNING: %d transport failures with %d threads\n", \
	       @failures[thread], thread) unless @failures[thread].nil?
      end
    end
  end

  def Bench.done
    if @@minfreq != 0
      `sudo /bin/sh -c \"echo #{@@minfreq} > #{MINFILE}\"`
    end
  end

  private
  @dir = nil

  protected

  @@ftime = 0
  @@printed_header = 0
  @@staprun = nil
  @@runtime = nil
  @@num_threads = []
  @@minfreq = 0

  def cleanup
    system('sudo killall -HUP staprun &> /dev/null')
    system('sudo /sbin/rmmod bench &> /dev/null')
    `/bin/rm -f stap.out` if File.exists?("stap.out")
    `/bin/rm -f bench.stp` if File.exists?("bench.stp")
    `/bin/rm -rf #{@dir}` unless @dir.nil?
    `/bin/rm -f stpd_cpu* probe.out`
  end

  def load
    args = "-q -b 8"
    if @trans == RELAYFS then args = "-q" end
    fork do exec "sudo #{@@staprun} #{args} #{@dir}/bench.ko > #{@dir}/xxx 2> #{@dir}/xxx.out" end
    sleep 5
  end

  def compile
    @dir = `mktemp -dt benchXXXXX`.strip
    emit_code
    modules = "/lib/modules/" + `uname -r`.strip + "/build"
    res=`make -C \"#{modules}\" M=\"#{@dir}\" modules V=1`
    if !File.exist?("#{@dir}/bench.ko")
      puts res
      cleanup
      exit
    end
  end

  def emit_code
    if @code
      begin
	f = File.new("#{@dir}/bench.c","w")
	f << "#include \"runtime.h\"
#include \"probes.c\"\n
MODULE_DESCRIPTION(\"SystemTap probe: bench\");
MODULE_AUTHOR(\"automatically generated by bench2/run_bench\");\n\n"
	f << "static int inst_sys_getuid (struct kprobe *p, struct pt_regs *regs) {\n"
	f << @code
	f << "\n  return 0;\n}\n"
	f << " static struct kprobe kp[] = {\n  {\n"
	f << "#if defined __powerpc64__ \n"
	f << "  .addr = (void *)\".sys_getuid\",\n"
	f << "#else \n"
	f << "  .addr = \"sys_getuid\", \n"
	f << "#endif\n"
	f << ".pre_handler = inst_sys_getuid\n  }\n};\n
#define NUM_KPROBES 1\n
int probe_start(void)\n{\n  return _stp_register_kprobes (kp, NUM_KPROBES);\n}\n
void probe_exit (void)\n{\n  _stp_unregister_kprobes (kp, NUM_KPROBES); \n}\n"
      rescue
	puts "Error writing source file"
	exit
      ensure
	f.close unless f.nil?
      end
      makefile = File.new("#{@dir}/Makefile","w")
      makefile << "CFLAGS += -Wno-unused -Werror
CFLAGS += -I \"#{@@runtime}\"
obj-m := bench.o
"
      makefile.close
    else
      puts "NO CODE!"
    end
  end

  def print_header
    @@printed_header = 1
    nproc=`grep ^processor /proc/cpuinfo`.count("\n")
    if nproc >= 16
      @@num_threads = [1,2,4,16]
    elsif nproc >= 8
      @@num_threads = [1,2,4,8]
    elsif nproc >= 4
      @@num_threads = [1,2,4]
    elsif nproc >= 2
      @@num_threads = [1,2]
    else
      @@num_threads = [1]
    end
    arch=`uname -m`.strip
    if (arch.match(/ppc64/))
	cpu=`grep "cpu" /proc/cpuinfo`.match(/(cpu\t\t: )([^\n]*)/)[2]
	clock=`grep "clock" /proc/cpuinfo`.match(/(clock\t\t: )([^\n]*)/)[2]
	revision=`grep "revision" /proc/cpuinfo`.match(/(revision\t: )([^\n]*)/)[2]
	cpuinfo=cpu + " " + clock + " revision: " + revision
    else
       	physical_cpus=`grep "physical id" /proc/cpuinfo`.split("\n").uniq.length
       	model=`grep "model name" /proc/cpuinfo`.match(/(model name\t: )([^\n]*)/)[2]
	cpuinfo="(#{physical_cpus} physical) #{model}"
    end	
    puts "SystemTap BENCH2 \t" + `date`
    puts "kernel: " + `uname -r`.strip + " " + `uname -m`.strip
    puts IO.read("/etc/redhat-release") if File.exists?("/etc/redhat-release")
    puts `uname -n`.strip + ": " + `uptime`
    puts "processors: #{nproc} #{cpuinfo}"

    begin
      mem=IO.read("/proc/meminfo").split("\n")
      puts mem[0] + "\t" + mem[1]
    rescue
    end
    puts "-"*64
    check_cpuspeed
    @@ftime = `./itest 1`.to_i
    puts "For comparison, function call overhead is #@@ftime nsecs."
      puts "Times below are nanoseconds per probe and include kprobe overhead."
    puts "-"*64
    puts "+--- S = Script, R = Runtime"
    puts "|+-- * = Relayfs        \tThreads"
    printf "|| NAME                 "
    @@num_threads.each {|n| printf("\t    %d",n)}
    printf "\n"
  end

  def check_cpuspeed
    if @@minfreq == 0 && File.exist?(MAXFILE)
      maxfreq = `cat #{MAXFILE}`.to_i
      @@minfreq = `cat #{MINFILE}`.to_i
      if @@minfreq != maxfreq
	`sudo /bin/sh -c \"echo #{maxfreq} > #{MINFILE}\"`
	sleep 1
      end
    end
  end
end

class Stapbench < Bench
  protected

  def load
    # we do this in several steps because the compilation phase can take a long time
    args = "-kvvp4"
    if @trans == RELAYFS then args = "-bMkvvp4" end
    res = `stap #{args} -m bench bench.stp &> stap.out`
    if $? != 0
      puts "ERROR running stap\n#{res}"
      puts IO.read("stap.out") if File.exists?("stap.out")
      cleanup
      exit
    end
    IO.foreach("stap.out") {|line| @dir = line if line =~ /Created temporary directory/} 
    @dir = @dir.match(/"([^"]*)/)[1]
    if !File.exist?("#{@dir}/bench.ko")
      puts `cat stap.out`
      cleanup
      exit
    end
    args = "-q -b 8"
    if @trans == RELAYFS then args = "-q" end
    fork do exec "sudo #{@@staprun} #{args} #{@dir}/bench.ko > #{@dir}/xxx 2> #{@dir}/xxx.out" end
    sleep 5
  end
  
  def compile
    emit_code
  end
  
  def emit_code
    if @file
      File.open("bench.stp","w") do |b|
	File.open(@file,"r") do |f|
	  f.each_line do |line|
	    b.puts(line.sub(/TEST/,'kernel.function("sys_getuid")'))
	  end
	end
      end
    elsif @code
      begin
	f = File.new("bench.stp","w")
	f << "probe kernel.function(\"sys_getuid\") {\n"
	f << @code
	f << "\n}\n"
      rescue
	puts "Error writing source file"
      ensure
	f.close unless f.nil?
      end
    else
      puts "NO CODE!"
    end
  end
end
