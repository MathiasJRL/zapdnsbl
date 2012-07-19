#
# zapdnsbl.tcl  Version: 0.6-dev  Author: Stefan Wold <ratler@stderr.eu>
###
# Info:
# ZAP DNS Blacklist is a script that take the host of a user joining
# a channel and check it against configured DNS blacklists (RBL). The
# configuration file is very similar to the format of BOPM.
###
# Require / Dependencies
# tcl >= 8.5
# tcllib >= 1.10 (http://www.tcl.tk/software/tcllib/)
###
# Installation:
# Copy zapdnsbl.tcl and zapdnsbl.ini to your_eggdrop/scripts/zapdnsbl/ then
# add source scripts/zapdnsbl/zapdnsbl.tcl in your eggdrop.conf.
# Reload (rehash) or restart your bot, that is it.
###
# Usage:
# chanset <channel> <+/->zapdnsbl
# This will either enable (+) or disable (-) the script for the
# specified channel
#
# chanset <channel> zapdnsbl.bantime <integer>
# For how long should the ban be active in minutes, if unset the
# script default to 120 minutes
#
# chanset <channel> <+/->zapdnsbl.pubcmd
# Enable (+) or disable (-) public commands (!zapblcheck <host>)
#
###
# LICENSE:
# Copyright (C) 2010 - 2012  Stefan Wold <ratler@stderr.eu>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

# ZAP DNS Blacklist

if {[namespace exists ::zapdnsbl]} {namespace delete ::zapdnsbl}
namespace eval ::zapdnsbl {
    # Path to configuration file
    variable inifile "scripts/zapdnsbl/zapdnsbl.ini"

    # Set console output flag, for debug purpose (default d, ie .console +d)
    variable conflag d
}


# ---- Only edit stuff below this line if you know what you are doing ----

# Channel flags
setudef flag zapdnsbl
setudef flag zapdnsbl.pubcmd
setudef int zapdnsbl.bantime

# Packages
package require Tcl 8.5
package require inifile
package require dns

# Bindings
bind evnt - prerehash ::zapdnsbl::onEvent
bind evnt - save ::zapdnsbl::onEvent
bind evnt - sigquit ::zapdnsbl::onEvent
bind evnt - sigterm ::zapdnsbl::onEvent
bind join - * ::zapdnsbl::onJoin
bind dcc - zapblcheck ::zapdnsbl::dccCheckDnsbl
bind dcc m|o zapblconfig ::zapdnsbl::dccConfig
bind dcc - help ::stderreu::help
bind pub - !zapblcheck ::zapdnsbl::pubCheckDnsbl

# Print debug
proc ::zapdnsbl::debug { text } {
    putloglev $::zapdnsbl::conflag * "$::zapdnsbl::name - DEBUG: $text"
}

namespace eval ::zapdnsbl {
    # Global variables
    variable version "0.6-dev"
    variable name "zapdnsbl"
    variable longName "ZAP DNS Blacklist"
    variable ini


    # Parse INI file
    if {[file exists $::zapdnsbl::inifile]} {
        # Open ini file in read-write mode for easy updating
        set ::zapdnsbl::ini [::ini::open $::zapdnsbl::inifile r+]
        foreach section [::ini::sections $::zapdnsbl::ini] {
            if {[regexp {^bl\:} $section]} {
                ::zapdnsbl::debug "Loading blacklist '$section'"
            } else {
                ::zapdnsbl::debug "Loading $::zapdnsbl::name '$section'"
            }
        }
    }
}
###
# Functions
###
proc ::zapdnsbl::saveAndCloseIniFile { } {
    putlog "$::zapdnsbl::name - Saving ini file"
    ::ini::commit $::zapdnsbl::ini
    ::ini::close $::zapdnsbl::ini
}

# onEvent: Used to watch certain events to act upon
proc ::zapdnsbl::onEvent { type } {
    ::zapdnsbl::debug "EVENT $type"
    switch -- $type {
        prerehash {
            ::zapdnsbl::saveAndCloseIniFile
        }
        save {
            putlog "$::zapdnsbl::name - Saving ini file"
            ::ini::commit $::zapdnsbl::ini

        }
        sigquit {
            ::zapdnsbl::saveAndCloseIniFile
        }
        sigterm {
            ::zapdnsbl::saveAndCloseIniFile
        }
    }
}

proc ::zapdnsbl::onJoin { nick host handle channel } {
    # Ignore myself
    if {[isbotnick $nick]} {
        ::zapdnsbl::debug "Found myself ($nick) - Ignoring"
        return 1
    }

    # Lower case channel
    set channel [string tolower $channel]

    # Only run if channel is defined
    if {![channel get $channel zapdnsbl]} { return 1 }

    # Exclude ops, voice, friends
    if {[matchattr $handle fov|fov $channel]} {
        putlog  "$::zapdnsbl::name - $nick is on exempt list"
        return 1
    }

    regexp ".+@(.+)" $host -> iphost
    set iphost [string tolower $iphost]

    # Get ip from host
    set ip [::zapdnsbl::getIp $iphost]
    if {$ip == 0} { return 0 }

    # Do the DNSBL black magic
    set dnsblData [::zapdnsbl::dnsCheckDnsbl $ip $iphost]

    if {[dict get $dnsblData status] == "FOUND" } {
        # Check if unknown is enabled or abort
        if {![::zapdnsbl::isBanUnknownEnabled "bl:[dict get $dnsblData blacklist]"] && [dict get $dnsblData reason] == "Unknown"} {
            ::zapdnsbl::debug "Host '$nick!$host ([dict get $dnsblData ip])' found in [dict get $dnsblData blacklist] reason '[dict get $dnsblData reason]', will not ban because ban_unknown is set to false"
            return 1
        }
        putlog  "$::zapdnsbl::name - Host '$nick!$host ([dict get $dnsblData ip])' found in [dict get $dnsblData blacklist] reason '[dict get $dnsblData reason]' on channel '$channel', banning with reason '[dict get $dnsblData banreason]'!"
        set bantime [channel get $channel zapdnsbl.bantime]
        if {$bantime == 0} {
            putlog "$::zapdnsbl::name - Bantime not set, defaulting to 120 minutes, set with .chanset $channel zapdnsbl.bantime <integer>."
            set bantime 120
        }

        newchanban $channel "*!*@$iphost" $::zapdnsbl::name [dict get $dnsblData banreason] $bantime
        return 1
    }
    ::zapdnsbl::debug "Host '$iphost' was not found in any blacklist, status [dict get $dnsblData status] - [dict get $dnsblData ip] - channel $channel"
}

# Public channel command to check if host appear in a DNS blacklist
proc ::zapdnsbl::pubCheckDnsbl { nick host handle channel arg } {
    if {![channel get $channel zapdnsbl.pubcmd]} { return 0 }
    set ip [::zapdnsbl::getIp $arg]
    if {$ip == 0} { return 0 }

    # Do the DNSBL black magic
    set dnsblData [::zapdnsbl::dnsCheckDnsbl $ip $arg]

    if {[dict get $dnsblData status] == "FOUND"} {
        puthelp "PRIVMSG $channel :$nick: $::zapdnsbl::name - Host '[dict get $dnsblData ip] ([dict get $dnsblData host])' found in [dict get $dnsblData blacklist] reason '[dict get $dnsblData reason]'"
    } else {
        puthelp "PRIVMSG $channel :$nick: $::zapdnsbl::name - Host '[dict get $dnsblData host]' is OK"
    }
}

# testHost - .zapblcheck <host>
proc ::zapdnsbl::dccCheckDnsbl { nick idx host } {
    if {[llength [split $host]] != 1} {
        ::stderreu::zapblcheck $idx; return 0
    }

    set host [string tolower $host]

    # Check if it is a numeric host
    set ip [::zapdnsbl::getIp $host]
    if {$ip == 0} { return 0 }

    set dnsblData [::zapdnsbl::dnsCheckDnsbl $ip $host]

    if {[dict get $dnsblData status] == "FOUND"} {
        putlog "$::zapdnsbl::name - TEST: Host '[dict get $dnsblData ip] ([dict get $dnsblData host])' was found in [dict get $dnsblData blacklist] reason: [dict get $dnsblData reason]"
        putlog "$::zapdnsbl::name - TEST: Ban message for '[dict get $dnsblData host]': [dict get $dnsblData banreason]"
    } else {
        putlog "$::zapdnsbl::name - TEST: Host '[dict get $dnsblData ip] ([dict get $dnsblData host])' was NOT found in any blacklist, status [dict get $dnsblData status]"
    }
}

proc ::zapdnsbl::dccConfig { nick idx arg } {
    if {!([llength [split $arg]] > 0)} {
        ::stderreu::zapblconfig $idx; return 0
    }

    set key [string tolower [lindex [split $arg] 0]]
    set value [join [lrange [split $arg] 1 end]]


    # Allowed string options
    set allowed_str_opts [list nameserver dnstimeout bl]

    # Allowed boolean options
    #set allowed_bool_opts [list ]
    if {[lsearch -exact $allowed_str_opts $key] != -1} {
        if {$key == "nameserver" && $value != ""} {
            if {[regexp {[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}$} $value]} {
                ::zapdnsbl::setConfigValuePair options $key $value
                putdcc $idx "$::zapdnsbl::name: Option '$key' set with the value '$value'"
            } else {
                putdcc $idx "$::zapdnsbl::name: Invalid ip address ($value) for option 'nameserver'"
            }
        } elseif {$key == "dnstimeout" && $value != ""} {
            if {[regexp {[0-9]+} $value]} {
                ::zapdnsbl::setConfigValuePair options $key $value
                putdcc $idx "$::zapdnsbl::name: Option '$key' set with the value '$value'"
            } else {
                putdcc $idx "$::zapdnsbl::name: Invalud value for dnstimeout, must be an integer."
            }
        } elseif {$key == "bl"} {
            if {[llength [split $value]] > 0} {
                set action [lindex [split $value] 0]

                switch -- $action {
                    list {
                        putidx $idx "### $::zapdnsbl::name - Loaded blacklists"
                        foreach section [::ini::sections $::zapdnsbl::ini] {
                            if {[regexp {^bl\:} $section]} {
                                putidx $idx "   [lindex [split $section ":"] 1]"
                                foreach {k v} [::ini::get $::zapdnsbl::ini $section] {
                                    putidx $idx "      $k = $v"
                                }
                                putidx $idx ""
                            }
                        }
                    }
                    default {
                        putidx $idx "$::zapdnsbl::name - Unknown action '$action'."
                        ::stderreu::zapblconfig $idx
                    }
                }
            } else {
                putidx $idx "$::zapdnsbl::name - Missing arguments."
                ::stderreu::zapblconfig $idx
            }
        } elseif {$value != ""} {
            ::zapdnsbl::setConfigValuePair options $key $value
            putdcc $idx "$::zapdnsbl::name: Option '$key' set with the value '$value'"
        } else {
            ::zapdnsbl::setConfigValuePair options $key ""
            putdcc $idx "$::zapdnsbl::name: Option '$key' unset"
        }
    }
}

proc ::zapdnsbl::dnsCheckDnsbl { ip host } {
    # Reverse the IP
    regexp {([0-9]{1,3}).([0-9]{1,3}).([0-9]{1,3}).([0-9]{1,3})} $ip -> oct1 oct2 oct3 oct4
    set reverseIp "$oct4.$oct3.$oct2.$oct1"

    # Default dnsbl stuff
    dict set dnsblData status "OK"
    dict set dnsblData ip $ip
    dict set dnsblData host $host

    foreach bl [::ini::sections $::zapdnsbl::ini] {
        ::zapdnsbl::debug "Trying blacklist $bl ($ip)"
        if {[regexp {^bl\:} $bl]} {
            set dnsbl [lindex [split $bl ":"] end]
            set address [::zapdnsbl::dnsQuery $reverseIp.$dnsbl dnsbl]
            if {[regexp {^[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}$} [lindex $address 0]]} {
                dict set dnsblData status "FOUND"

                foreach ipAdd $address {
                    set blr [::zapdnsbl::getDnsblReason $bl $ipAdd]
                    if {[info exists reason] && [lsearch $reason $blr] == -1} {
                        lappend reason $blr
                    } elseif {![info exists reason]} {
                        lappend reason $blr
                    }
                }

                set reason [join [lsort $reason] ", "]
                set template [list %reason% $reason \
                                  %ip% $ip]
                dict set dnsblData reason $reason
                dict set dnsblData banreason [::zapdnsbl::template [::zapdnsbl::getBanReason $bl] $template]
                dict set dnsblData blacklist $dnsbl

                return $dnsblData
            }
        }
    }
    return $dnsblData
}

proc ::zapdnsbl::dnsQuery { host mode } {
    set timer [clock clicks -milliseconds]
    set dnsTimeout 30000
    if {[::ini::exists $::zapdnsbl::ini options dnstimeout]} {
        set timeout [::ini::value $::zapdnsbl::ini options dnstimeout]
        if {$timeout > 0} {
            set dnsTimeout [expr {int($timeout * 1000)}]
            ::zapdnsbl::debug "DNS timeout set to $dnsTimeout milliseconds"
        }
    }
    if {[::ini::exists $::zapdnsbl::ini options nameserver]} {
        set nameserver [::ini::value $::zapdnsbl::ini options nameserver]
        ::zapdnsbl::debug "Nameserver override detected, forced to '$nameserver'"
        set result [::dns::resolve $host -server $nameserver -timeout $dnsTimeout]
    } else {
        set result [::dns::resolve $host -timeout $dnsTimeout]
    }

    ::dns::wait $result
    ::zapdnsbl::debug "Query time ($host): [expr {int([clock clicks -milliseconds] - $timer)}] msec"

    switch -- [::dns::status $result] {
        ok {
            # Just pick the first entry if a list is returned
            set address [::dns::address $result]
            ::zapdnsbl::debug "Resolved address $address"
            ::dns::cleanup $result
            return $address
        }
        error {
            set error [::dns::error $result]
            ::dns::cleanup $result
            if {$mode == "resolve"} {
                return $error
            } elseif {$mode == "dnsbl" && [string match "domain does not exist" $error]} {
                return ""
            }
            return $error
        }
        timeout {
            putlog "$::zapdnsbl::name - dnsQuery() timeout ($host)"
            return ""
        }
        eof {
            putlog "$::zapdnsbl::name - dnsQuery() eof"
            return ""
        }
    }
}

# This function will replace %keywords% with supplied substitutes
proc ::zapdnsbl::template { text subs } {
    foreach {arg1 arg2} $subs {
        regsub -all -- $arg1 $text $arg2 text
    }
    return $text
}

###
# Getters
###

# Getter to retrieve a reason from the ini file
proc ::zapdnsbl::getDnsblReason { bl address } {
    # Last octet in $address is the reason matched against reply:X
    set lastOctet [lindex [split $address "."] end]
    if {[::ini::exists $::zapdnsbl::ini $bl reply:$lastOctet]} {
        set reason [::ini::value $::zapdnsbl::ini $bl reply:$lastOctet]
        return $reason
    }
    return "Unknown"
}

# Getter to retrieve a ban reason
proc ::zapdnsbl::getBanReason { bl } {
    if {[::ini::exists $::zapdnsbl::ini $bl ban_message]} {
        return [::ini::value $::zapdnsbl::ini $bl ban_message]
    } elseif {[::ini::exists $::zapdnsbl::ini $bl default_ban_message]} {
        return [::ini::value $::zapdnsbl::ini $bl default_ban_message]
    }
    return ""
}

# Getter to retrieve ip from host
proc ::zapdnsbl::getIp { iphost } {
    if {![regexp {^[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}$} $iphost]} {
        set ip [::zapdnsbl::dnsQuery $iphost resolve]
        if {![regexp {[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}$} $ip]} {
            ::zapdnsbl::debug "DNS ERROR: $ip"
            putlog "$::zapdnsbl::name - Couldn't resolve '$iphost'. No further action taken."

            # Abort if we fail to resolve the host
            return 0
        }
    } else {
        set ip $iphost
    }
    return $ip
}

# Getter to retrieve ban_unknown from a blacklist, returns true or false
proc ::zapdnsbl::isBanUnknownEnabled { bl } {
    if {[::ini::exists $::zapdnsbl::ini $bl ban_unknown] && [string tolower [::ini::value $::zapdnsbl::ini $bl ban_unknown]] == "true"} {
        return 1
    }
    return 0
}

###
# Setters
###
proc ::zapdnsbl::setConfigValuePair { section key value } {
    # If value is empty remove the key
    if {$value == ""} {
        ::ini::delete $::zapdnsbl::ini $section $key
    } else {
        ::ini::set $::zapdnsbl::ini $section $key $value
    }
    # Check if section have keys if not delete the section
    if {[llength [::ini::keys $::zapdnsbl::ini $section]] == 0} {
        ::ini::delete $::zapdnsbl::ini $section
        ::zapdnsbl::debug "Section '$section' empty - deleted"
    }
}

namespace eval ::stderreu {
    variable helpfuncs

    dict set ::stderreu::helpfuncs zapdnsbl [list zapdnsbl zapblcheck zapblconfig]
}

proc ::stderreu::zapdnsbl { idx } {
    putidx $idx "\n\n\002$::zapdnsbl::longName v$::zapdnsbl::version\002 by Ratler"
    ::stderreu::zapblcheck $idx
}

proc ::stderreu::zapblcheck { idx } {
    putidx $idx "### \002zapblcheck <host>"
}

proc ::stderreu::zapblconfig { idx } {
    putidx $idx "### \002zablconfig <option> \[value\]\002"
    putidx $idx "    \002Options\002:"
    putidx $idx "      nameserver \[ip\]       : Override system default DNS resolver configuration."
    putidx $idx "                              NOTE: This option is necessary for windrop users."
    putidx $idx "      dnstimeout \[seconds\]  : Set timeout for DNS queries, default is 30 seconds."
    putidx $idx "      bl <action>           : Manage blacklists"
    putidx $idx "                              Valid actions: list"
    putidx $idx "    \002*NOTE*\002:"
    putidx $idx "      To completely remove an option from the configuration leave \[value\] blank, ie .zapblconfig nameserver"
}
proc ::stderreu::zapdnsbldefault { idx } {
    putidx $idx "\n\n\002$::zapdnsbl::longName v$::zapdnsbl::version\002 commands:"
    putidx $idx "   \002zapblcheck    zapblconfig\002"
}

proc ::stderreu::help { hand idx arg } {
    set myarg [join $arg]
    set found 0
    # First we test if arg is all to print eggdrop builtin commands,
    # then we call the help proc ::stderreu::for each script loaded
    if {$myarg == "all"} {
        *dcc:help $hand $idx [join $arg]
        foreach key [dict keys $::stderreu::helpfuncs] {
            ::stderreu::$key $idx
        }
        return 1
    } else {
        foreach key [dict keys $::stderreu::helpfuncs] {
            foreach helpf [dict get $::stderreu::helpfuncs $key] {
                if {[string match -nocase $myarg $helpf]} {
                    ::stderreu::$helpf $idx
                    set found 1
                }
            }
        }
    }

    if {$found == 0 || [regexp {\*} $myarg]} {
        *dcc:help $hand $idx $myarg
    }

    if {[llength [split $arg]] == 0} {
        foreach key [dict keys $::stderreu::helpfuncs] {
            ::stderreu::${key}default $idx
        }
    }
    return 1
}

putlog "\002$::zapdnsbl::longName v$::zapdnsbl::version\002 by Ratler loaded"
