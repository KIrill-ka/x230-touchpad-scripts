#!/usr/bin/tclsh8.6
namespace import tcl::mathop::*

set data {}

proc process_input {} {
 set buf [read $::dev]
 binary scan $buf H* hex
 for {set i 0} {$i < [string length $hex]} {incr i 2} {
  set b [string range $hex $i $i+1]
  lappend ::data $b
 }
}

proc serio_set_raw {sysfs_path raw} {
 set fd [open $sysfs_path/drvctl w]
 if {$raw} {set mode "serio_raw"} else {set mode "psmouse"}
 puts -nonewline $fd $mode
 close $fd
 if {$raw} {
  while {1} {
   if {![catch {set rn [glob $sysfs_path/misc/*]}]} {
    set rn [file tail $rn]
    if {[file exists /dev/$rn]} {return /dev/$rn}
   }
   after 100
  }
 }
 while {1} {
  if {[file isdirectory $sysfs_path/input]} return
  after 100
 }
}

proc serio_get_byte {} {
 global data
 set b [lindex $data 0]
 set data [lreplace $data 0 0]
 return $b
}

proc ps2_get_status {} {
 set b [serio_get_byte]
 if {$b eq ""} {
  set timer [after 500 {lappend ::data timeout}]
  vwait data
  after cancel $timer
  set b [serio_get_byte]
 }
 switch $b {
  fa {return ack}
  fc {return error}
  fe {return resend}
  default {return $b}
 }
}

proc serio_get_pkt {len} {
 set pkt ""
 set timer [after 500 {lappend ::data timeout}]
 for {set i 0} {$i < $len} {incr i} {
  set b [serio_get_byte]
  if {$b eq ""} {
   vwait data
   set b [serio_get_byte]
  }
  if {$b eq "timeout"} return {}
  append pkt $b
 }
 after cancel $timer
 return $pkt
}

proc ps2_send_cmd {cmd} {
 switch $cmd {
  Disable {set cmd 0xF5}
  Enable {set cmd 0xF4}
  SetSampleRate {set cmd 0xF3}
  StatusRequest {set cmd 0xE9}
  SetResolution {set cmd 0xE8}
  SetScaling21 {set cmd 0xE7}
  SetScaling11 {set cmd 0xE6}
 }
 for {set i 0} {$i < 3} {incr i} {
  puts -nonewline $::dev [binary format c $cmd]
  set s [ps2_get_status]
  if {$s eq "ack"} return
  puts "$s"
  if {$s eq "resend"} {
   after 1000
   continue
  }
  error "unexpected status \"$s\""
 }
 error "to many attempts, last status was \"$s\""
}

proc ps2_send_ext_cmd {cmd} {
 switch $cmd {
  IdentifyTouchPad {set cmd 0x00}
  ReadTouchPadModes {set cmd 0x01}
  ReadCapabilities {set cmd 0x02}
  ReadModelId {set cmd 0x03}
  ExtendedModelId {set cmd 0x09}
  ContinuedCapabilities {set cmd 0x0C}
  RmiBackdoor {set cmd 0x7F}
 }
 ps2_send_cmd SetScaling11
 for {set i 3} {$i >= 0} {incr i -1} {
   ps2_send_cmd SetResolution
   set b [expr {($cmd >> ($i*2)) & 3}]
   ps2_send_cmd $b
 }
}

proc enter_iep {} {
 ps2_send_cmd Disable
 ps2_send_ext_cmd RmiBackdoor
 ps2_send_cmd SetSampleRate
 ps2_send_cmd 0x14 ;# Mode byte 2
}

proc rmi_read_reg {addr} {
 ps2_send_cmd SetScaling21
 ps2_send_cmd SetSampleRate
 ps2_send_cmd $addr
 ps2_send_cmd StatusRequest
 return [serio_get_pkt 1]
}

proc rmi_write_reg {addr val} {
 ps2_send_cmd SetScaling21
 ps2_send_cmd SetSampleRate
 ps2_send_cmd $addr
 ps2_send_cmd SetSampleRate
 ps2_send_cmd $val
}

proc rmi_read_pdt {page} {
 rmi_write_reg 0xff $page
 dict set pdt props [rmi_read_reg 0xef]
 set addr 0xee
 while {1} {
  set func [rmi_read_reg $addr]; incr addr -1
  if {$func == 0} {return $pdt}
  set r 0x[rmi_read_reg $addr]; incr addr -1
  dict set pdt f$func func_ver [& [>> $r 5] 3]
  dict set pdt f$func irq_src_cnt [& $r 7]
  set r 0x[rmi_read_reg $addr]; incr addr -1
  dict set pdt f$func data_base $r
  set r 0x[rmi_read_reg $addr]; incr addr -1
  dict set pdt f$func ctrl_base $r
  set r 0x[rmi_read_reg $addr]; incr addr -1
  dict set pdt f$func cmd_base $r
  set r 0x[rmi_read_reg $addr]; incr addr -1
  dict set pdt f$func query_base $r
 }
}

proc rmi_read_func_reg {pdt func reg_type off} {
# NOTE: assumes the page is already switched
 set b [dict get $pdt $func ${reg_type}_base]
 return 0x[rmi_read_reg [+ $b $off]]
}

proc rmi_write_func_reg {pdt func reg_type off val} {
# NOTE: assumes the page is already switched
 set b [dict get $pdt $func ${reg_type}_base]
 rmi_write_reg [+ $b $off] $val
}

proc rmi_print_f11 {pdt0} {
 set n_electrodes [rmi_read_func_reg $pdt0 f11 query 4]
 puts "n_electrodes: $n_electrodes"
 set a 0
 for {set i 0} {$i <= 11} {incr i} {
  puts "f11.ctrl$i: [rmi_read_func_reg $pdt0 f11 ctrl $a]"
  incr a
 }
 for {set i 0} {$i < $n_electrodes} {incr i} {
  puts "f11.ctrl12.$i: [rmi_read_func_reg $pdt0 f11 ctrl $a]"
  incr a
 }
 # NOTE: supposedly ctrl13 registers also consume n_electrodes
 incr a $n_electrodes
 # NOTE: presense of 14-19 should be determined based on query1 & query7
 puts "f11.ctrl15: [rmi_read_func_reg $pdt0 f11 ctrl $a]"
 incr a
 puts "f11.ctrl17: [rmi_read_func_reg $pdt0 f11 ctrl $a]"
 
 for {set i 0} {$i <= 10} {incr i} {
  puts "f11.query$i [rmi_read_func_reg $pdt0 f11 query $i]"
 }
}

set raw_fn [serio_set_raw "/sys/bus/serio/devices/serio1" 1]

set dev [open $raw_fn r+]
fconfigure $dev -blocking 0 -buffering none -translation binary
fileevent $dev readable process_input

#for {set i 0} {$i < 100} {incr i} {
# set p [serio_get_pkt 6]
# puts $p
# #if {$p eq ""} break
#}

ps2_send_cmd Disable

ps2_send_ext_cmd ReadCapabilities
ps2_send_cmd StatusRequest
puts "capabilities: [serio_get_pkt 3]"

ps2_send_ext_cmd ContinuedCapabilities
ps2_send_cmd StatusRequest
puts "cont capabilities: [serio_get_pkt 3]"

enter_iep

set pdt0 [rmi_read_pdt 0]
puts "PDT(0): $pdt0"

rmi_print_f11 $pdt0

set r [rmi_read_func_reg $pdt0 f11 ctrl 0]
if {$r & 8} {
 puts "AbsPosFilt enabled"
 set r [rmi_write_func_reg $pdt0 f11 ctrl 0 [& $r [~ 8]]]
} else {
 puts "AbsPosFilt disabled"
}
 
ps2_send_ext_cmd ReadCapabilities
ps2_send_cmd StatusRequest
puts "capabilities: [serio_get_pkt 3]"

ps2_send_ext_cmd ContinuedCapabilities
ps2_send_cmd StatusRequest
puts "cont capabilities: [serio_get_pkt 3]"

serio_set_raw "/sys/bus/serio/devices/serio1" 0
