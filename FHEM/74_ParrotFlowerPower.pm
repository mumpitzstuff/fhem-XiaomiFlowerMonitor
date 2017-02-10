###############################################################################
#
#  (c) 2016-2017 Copyright: Marko Oldenburg (leongaultier at gmail dot com)
#  All rights reserved
#
#  Modifications by: Achim Winkler
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#
# $Id$
#
###############################################################################


package main;

use strict;
use warnings;
use POSIX;

use Blocking;

my $version = "0.0.3";
my %colors = ( 1 => "brown",
               2 => "esmerald",
               3 => "lemon",
               4 => "gray-brown",
               5 => "gray-green",
               6 => "classic-green",
               7 => "grey-blue" );



# Declare functions
sub ParrotFlowerPower_Initialize($);
sub ParrotFlowerPower_Define($$);
sub ParrotFlowerPower_Undef($$);
sub ParrotFlowerPower_Attr(@);
sub ParrotFlowerPower_stateRequest($);
sub ParrotFlowerPower_stateRequestTimer($);
sub ParrotFlowerPower_Set($$@);
sub ParrotFlowerPower_Run($);
sub ParrotFlowerPower_BlockingRun($);
sub ParrotFlowerPower_callGatttool($$);
sub ParrotFlowerPower_readSensorValue($$$);
sub ParrotFlowerPower_convertStringToFloat($);
sub ParrotFlowerPower_convertStringToU8($);
sub ParrotFlowerPower_convertStringToU16($);
sub ParrotFlowerPower_convertHexToString($);
sub ParrotFlowerPower_round($$);
sub ParrotFlowerPower_BlockingDone($);
sub ParrotFlowerPower_BlockingAborted($);




sub ParrotFlowerPower_Initialize($) {
    my ($hash) = @_;

    
    $hash->{SetFn}      = "ParrotFlowerPower_Set";
    $hash->{DefFn}      = "ParrotFlowerPower_Define";
    $hash->{UndefFn}    = "ParrotFlowerPower_Undef";
    $hash->{AttrFn}     = "ParrotFlowerPower_Attr";
    $hash->{AttrList}   = "interval ".
                          "disabledForIntervals ".
                          "disable:1 ".
                          "hciDevice:hci0,hci1,hci2 ".
                          "decimalPlaces:1,2,3,4,5,6 ".
                          "minSoilMoisture ".
                          "maxSoilMoisture ".
                          "minTemperature ".
                          "maxTemperature ".
                          "minSunlight ".
                          "maxSunlight ".
                          $readingFnAttributes;

    foreach my $d(sort keys %{$modules{ParrotFlowerPower}{defptr}}) {
        my $hash = $modules{ParrotFlowerPower}{defptr}{$d};
        $hash->{VERSION} = $version;
    }
}

sub ParrotFlowerPower_Define($$) {
    my ( $hash, $def ) = @_;
    my @a = split( "[ \t][ \t]*", $def );

    return "too few parameters: define <name> ParrotFlowerPower <BTMAC>" if ( @a != 3 );

    my $name                = $a[0];
    my $mac                 = $a[2];

    $hash->{BTMAC}          = $mac;
    $hash->{VERSION}        = $version;
    $hash->{INTERVAL}       = 3600;
    $hash->{HCIDEVICE}      = "hci0";
    $hash->{DECIMALPLACES}  = 4;

    $modules{ParrotFlowerPower}{defptr}{$hash->{BTMAC}} = $hash;
    readingsSingleUpdate( $hash, "state", "initialized", 0 );
    
    RemoveInternalTimer( $hash );

    if ( $init_done ) {
        ParrotFlowerPower_stateRequestTimer( $hash );
    } else {
        InternalTimer( gettimeofday() + int(rand(30)) + 15, "ParrotFlowerPower_stateRequestTimer", $hash, 0 );
    }

    Log3 $name, 3, "ParrotFlowerPower ($name) - defined with BTMAC $hash->{BTMAC}";

    $modules{ParrotFlowerPower}{defptr}{$hash->{BTMAC}} = $hash;
    return undef;
}

sub ParrotFlowerPower_Undef($$) {
    my ( $hash, $arg ) = @_;
    my $mac = $hash->{BTMAC};
    my $name = $hash->{NAME};


    RemoveInternalTimer($hash);
    BlockingKill( $hash->{helper}{RUNNING_PID} ) if ( defined($hash->{helper}{RUNNING_PID}) ); 

    delete( $modules{ParrotFlowerPower}{defptr}{$mac} );
    Log3 $name, 3, "Sub ParrotFlowerPower_Undef ($name) - delete device";
    return undef;
}

sub ParrotFlowerPower_Attr(@) {
    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash                                = $defs{$name};


    if ( $attrName eq "disable" ) {
        if ( $cmd eq "set" and $attrVal eq "1" ) {
            readingsSingleUpdate ( $hash, "state", "disabled", 1 );
            
            Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - disabled";
        }
        elsif ( $cmd eq "del" ) {
            readingsSingleUpdate ( $hash, "state", "active", 1 );
            
            Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - enabled";
        }
    }

    if ( $attrName eq "disabledForIntervals" ) {
        if ( $cmd eq "set" ) {
            readingsSingleUpdate ( $hash, "state", "suspended", 1 );
            
            Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - disabledForIntervals";
        }
        elsif ( $cmd eq "del" ) {
            readingsSingleUpdate ( $hash, "state", "active", 1 );
            
            Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - enabled";
        }
    }

    if ( $attrName eq "interval" ) {
        if ( $cmd eq "set" ) {
            if ( $attrVal < 900 ) {
                Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - interval too small, please use something >= 900 (sec), default is 3600 (sec)";
                return "interval too small, please use something >= 900 (sec), default is 3600 (sec)";
            } else {
                $hash->{INTERVAL} = $attrVal;
                Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - set interval to $attrVal";
            }
        }
        elsif( $cmd eq "del" ) {
            $hash->{INTERVAL} = 3600;
            Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - set interval to default";
        }
    }
    
    if ( $attrName eq "hciDevice" ) {
        if ( $cmd eq "set" ) {
            $hash->{HCIDEVICE} = $attrVal;
            Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - set hciDevice to $attrVal";
        }
        elsif( $cmd eq "del" ) {
            $hash->{HCIDEVICE} = "hci0";
            Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - set hciDevice to default";
        }
    }
    
    if ( $attrName eq "decimalPlaces" ) {
        if ( $cmd eq "set" ) {
            $hash->{DECIMALPLACES} = $attrVal;
            Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - set decimalPlaces to $attrVal";
        }
        elsif( $cmd eq "del" ) {
            $hash->{DECIMALPLACES} = 4;
            Log3 $name, 3, "ParrotFlowerPower_Attr ($name) - set decimalPlaces to default";
        }
    }

    return undef;
}

sub ParrotFlowerPower_stateRequest($) {
    my ($hash)      = @_;
    my $name        = $hash->{NAME};


    if ( !IsDisabled($name) ) {
        readingsSingleUpdate ( $hash, "state", "active", 1 );

        ParrotFlowerPower_Run( $hash );
    } else {
        readingsSingleUpdate ( $hash, "state", "disabled", 1 );
    }
    
    Log3 $name, 5, "Sub ParrotFlowerPower_stateRequestTimer ($name) - state request called";
}

sub ParrotFlowerPower_stateRequestTimer($) {
    my ($hash)      = @_;
    my $name        = $hash->{NAME};


    RemoveInternalTimer($hash);

    if ( !IsDisabled($name) ) {
        readingsSingleUpdate ( $hash, "state", "active", 1 );

        ParrotFlowerPower_Run( $hash );
    } else {
        readingsSingleUpdate ( $hash, "state", "disabled", 1 );
    }

    InternalTimer( gettimeofday() + $hash->{INTERVAL} + int(rand(30)), "ParrotFlowerPower_stateRequestTimer", $hash, 1 );

    Log3 $name, 5, "Sub ParrotFlowerPower_stateRequestTimer ($name) - state request timer called";
}

sub ParrotFlowerPower_Set($$@) {
    my ($hash, $name, @aa)  = @_;
    my ($cmd, $arg)         = @aa;

    
    if ( $cmd eq 'statusRequest' ) {
        ParrotFlowerPower_stateRequest( $hash );
    } else {
        my $list = "statusRequest:noArg";
        return "Unknown argument $cmd, choose one of $list";
    }

    return undef;
}

sub ParrotFlowerPower_Run($) {
    my ( $hash, $cmd )  = @_;
    my $name            = $hash->{NAME};
    my $mac             = $hash->{BTMAC};
    my $hci             = defined($hash->{HCIDEVICE}) ? $hash->{HCIDEVICE} : "hci0";
    my $decimalPlaces   = defined($hash->{DECIMALPLACES}) ? $hash->{DECIMALPLACES} : 4;

    
    if ( not exists($hash->{helper}{RUNNING_PID}) ) {
        Log3 $name, 4, "Sub ParrotFlowerPower_Run ($name) - start blocking call";
    
        readingsSingleUpdate ( $hash, "state", "read data", 1 );
    
        $hash->{helper}{RUNNING_PID} = BlockingCall( "ParrotFlowerPower_BlockingRun", $name."|".$mac."|".$hci."|".$decimalPlaces, 
                                                     "ParrotFlowerPower_BlockingDone", 60 + 120, 
                                                     "ParrotFlowerPower_BlockingAborted", $hash );
    } else {
        Log3 $name, 4, "Sub ParrotFlowerPower_Run ($name) - blocking call already running";    
    }
}

sub ParrotFlowerPower_BlockingRun($) {
    my ($string)        = @_;
    my ($name, $mac)    = split("\\|", $string);
    

    Log3 $name, 4, "Sub ParrotFlowerPower_BlockingRun ($name) - read data from sensor";

    ##### read sensor data
    my $result = ParrotFlowerPower_callGatttool( $name, $mac );

    Log3 $name, 4, "Sub ParrotFlowerPower_BlockingRun ($name) - read data finished: $result";

    return "$name|$result";
}

sub ParrotFlowerPower_callGatttool($$) {
    my ( $name, $mac, $hci, $decimalPlaces ) = @_;
    my $loop                = 0;
    my $isFreeSlot          = 0;
    my $result;
    my $deviceName          = ReadingsVal( $name, "deviceName", "" );
    my $deviceColor         = ReadingsVal( $name, "deviceColor", "" );
    my $batteryLevel        = "";
    my $calibSoilMoisture   = "";
    my $calibAirTemperature = "";
    my $calibSunlight       = "";


    # wait up to 60s to get a free slot
    do {
        $result = qx(ps ax | grep -v grep | grep -iE "gatttool|hcitool");
        
        # hci0: only hci1-9 is allowed for gatttool or hcitool
        # hci1-9: same interface is not allowed for gatttool or hcitool
        if ( ("" ne $result) && 
              ((("hci0" eq $hci) && (not $result =~ /\-i hci[1-9]/)) ||
               (("hci0" ne $hci) && ($result =~ /\-i $hci/))) ) {
            Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - check if gattool or hcitool is running. loop: $loop";
            sleep 1;
            $loop++;
        } else {
            $isFreeSlot = 1;
        }
    }
    while ( $loop < 60 && 0 == $isFreeSlot );
    
    if ( $isFreeSlot ) {    
        #### Read Sensor Data
        Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - run gatttool";

        if ( "" eq $deviceName ) {
            $deviceName = ParrotFlowerPower_convertHexToString( ParrotFlowerPower_readSensorValue( $name, $mac, "00002a00-0000-1000-8000-00805f9b34fb" ) );
            Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - processing gatttool response. deviceName: $deviceName";
        } else {
            Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - deviceName already available: $deviceName";
        }

        if ( "" eq $deviceColor ) {
            $deviceColor = ParrotFlowerPower_convertStringToU16( ParrotFlowerPower_readSensorValue( $name, $mac, "39e1fe04-84a8-11e2-afba-0002a5d5c51b" ) );
            $deviceColor = $colors{$deviceColor} if ( exists($colors{$deviceColor}) );
            Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - processing gatttool response. deviceColor: $deviceColor";
        } else {
            $deviceColor = $colors{$deviceColor} if ( exists($colors{$deviceColor}) );
            Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - deviceColor already available: $deviceColor";
        }    
        
        $batteryLevel = ParrotFlowerPower_convertStringToU8( ParrotFlowerPower_readSensorValue( $name, $mac, "00002a19-0000-1000-8000-00805f9b34fb" ) );
        Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - processing gatttool response. batteryLevel: $batteryLevel";
        
        $calibSoilMoisture = ParrotFlowerPower_round( ParrotFlowerPower_convertStringToFloat( ParrotFlowerPower_readSensorValue( $name, $mac, "39e1fa09-84a8-11e2-afba-0002a5d5c51b" ) ), $decimalPlaces );
        Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - processing gatttool response. calibSoilMoisture: $calibSoilMoisture";
        
        $calibAirTemperature = ParrotFlowerPower_round( ParrotFlowerPower_convertStringToFloat( ParrotFlowerPower_readSensorValue( $name, $mac, "39e1fa0a-84a8-11e2-afba-0002a5d5c51b" ) ), $decimalPlaces );
        Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - processing gatttool response. calibAirTemperature: $calibAirTemperature";
        
        $calibSunlight = ParrotFlowerPower_round( ParrotFlowerPower_convertStringToFloat( ParrotFlowerPower_readSensorValue( $name, $mac, "39e1fa0b-84a8-11e2-afba-0002a5d5c51b" ) ), $decimalPlaces );
        Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - processing gatttool response. calibSunlight: $calibSunlight";
    } else {
        Log3 $name, 4, "Sub ParrotFlowerPower_callGatttool ($name) - no free slot found to start gatttool";
    }
    
    return "$deviceName|$deviceColor|$batteryLevel|$calibSoilMoisture|$calibAirTemperature|$calibSunlight";
}

sub ParrotFlowerPower_readSensorValue($$$) {
    my ($name, $mac, $uuid ) = @_;
    my $hci = ReadingsVal( $name, "hciDevice", "hci0" );
    my $result;
    my $loop = 0;

    
    do {
        # try to read the value from sensor
        $result = qx( gatttool -i $hci -b $mac --char-read --uuid=$uuid 2>&1 );
        Log3 $name, 4, "Sub ParrotFlowerPower_readSensorValue ($name) - call gatttool char read loop: $loop, result: $result";
        $loop++;
    }
    while ( ($loop < 10) && (not $result =~ /handle\:.*value\:(.*)/) );

    if ( defined($1) ) {
        $result = $1;
        
        # remove spaces
        $result =~ s/\s//g;
        
        Log3 $name, 4, "Sub ParrotFlowerPower_readSensorValue ($name) - processing gatttool response: $result";

        return $result;
    } else {
        Log3 $name, 4, "Sub ParrotFlowerPower_readSensorValue ($name) - invalid gatttool response";
        
        # return empty string in case of an error
        return "";
    }
}

sub ParrotFlowerPower_convertStringToFloat($) {
    $_ = shift;

    if ( "" ne $_ ) {
        # switch endianess of string
        $_ = unpack( "H*", reverse(pack("H*", $_)) );

        # convert string to float
        return unpack( "f", pack("L", hex($_)) );
    } else {
        return "";
    }
}

sub ParrotFlowerPower_convertStringToU8($) {
    $_ = shift;

    if ( "" ne $_ ) {
        # convert string to U8
        return hex($_);
    } else {
        return "";
    }
}

sub ParrotFlowerPower_convertStringToU16($) {
    $_ = shift;

    if ( "" ne $_ ) {
        # switch endianess of string
        $_ = unpack( "H*", reverse(pack("H*", $_)) );

        # convert string to U16
        return hex($_);
    } else {
        return "";
    }
}

sub ParrotFlowerPower_convertHexToString($) {
    $_ = shift;

    if ( "" ne $_ ) {
        # convert hex string into string
        return pack( "H*", $_ );
    } else {
        return "";
    }
}

sub ParrotFlowerPower_round($$) {
    my ( $value, $decimalPlaces ) = @_;
 
    if ( "" ne $value ) {
        return ( int(($value * (10**$decimalPlaces)) + 0.5) / (10**$decimalPlaces) );
    } else {
        return "";
    }
}

sub ParrotFlowerPower_BlockingDone($) {
    my ($string)            = @_;
    my ( $name, $deviceName, $deviceColor, $batteryLevel, $calibSoilMoisture, $calibAirTemperature, $calibSunlight ) = split( "\\|", $string );
    my $hash                = $defs{$name};


    delete($hash->{helper}{RUNNING_PID});

    Log3 $name, 4, "Sub ParrotFlowerPower_BlockingDone ($name) - helper disabled. abort" if ( $hash->{helper}{DISABLED} );
    return if ( $hash->{helper}{DISABLED} );

    readingsBeginUpdate( $hash );

    readingsBulkUpdate( $hash, "deviceName", $deviceName );
    readingsBulkUpdate( $hash, "deviceColor", $deviceColor );
    readingsBulkUpdate( $hash, "battery", (("" eq $batteryLevel) || ($batteryLevel > 15)) ? "ok" : "low" );
    readingsBulkUpdate( $hash, "batteryLevel", $batteryLevel );
    readingsBulkUpdate( $hash, "soilMoisture", $calibSoilMoisture );
    readingsBulkUpdate( $hash, "airTemperature", $calibAirTemperature );
    readingsBulkUpdate( $hash, "sunlight", $calibSunlight );
    readingsBulkUpdate( $hash, "state", "M: ".$calibSoilMoisture." % T: ".$calibAirTemperature." °C L: ".$calibSunlight." lux B: ".$batteryLevel." %" );
    #readingsBulkUpdate( $hash, "state", "active" );
        
    readingsEndUpdate( $hash, 1 );

    Log3 $name, 4, "Sub ParrotFlowerPower_BlockingDone ($name) - done";
}

sub ParrotFlowerPower_BlockingAborted($) {
    my ($hash)  = @_;
    my $name    = $hash->{NAME};

    delete( $hash->{helper}{RUNNING_PID} );
    readingsSingleUpdate( $hash, "state", "unreachable", 1);
    
    Log3 $name, 3, "($name) Sub ParrotFlowerPower_BlockingAborted - BlockingCall process terminated unexpectedly: timeout";
}

1;








=pod
=item device
=item summary       Modul to retrieves data from a Parrot Flower Power Sensors
=item summary_DE    Modul um Daten vom Parrot Flower Power Sensor zu auszulesen

=begin html

<a name="ParrotFlowerPower"></a>
<h3>Parrot Flower Power</h3>
<ul>
  <u><b>ParrotFlowerPower - Retrieves data from a Parrot Flower Power Sensor</b></u>
  <br>
  With this module it is possible to read the data from a sensor and to set it as reading.</br>
  Gatttool is required to use this module. (apt-get install bluez)
  <br><br>
  <a name="ParrotFlowerPowerdefine"></a>
  <b>Define</b>
  <ul><br>
    <code>define &lt;name of plant&gt; ParrotFlowerPower &lt;BT-MAC&gt;</code>
    <br><br>
    Example:
    <ul><br>
      <code>define MyPlant ParrotFlowerPower C4:7C:8D:62:42:6F</code><br>
    </ul>
    <br>
    This command creates a ParrotFlowerPower with the Bluetooth Mac C4:7C:8D:62:42:6F.<br>
    After the device has been created, the current data of the Parrot Flower Power Sensor is automatically read.
  </ul>
  <br><br>
  <a name="ParrotFlowerPowerreadings"></a>
  <b>Readings</b>
  <ul>
    <li>state - status of the flower power sensor or error message if any errors.</li>
    <li>deviceName - name of the Parrot Flower Power sensor.</li>
    <li>deviceColor - color of the Parrot Flower Power sensor.</li>
    <li>battery - current battery state (depends on batteryLevel).</li>
    <li>batteryLevel - current battery level.</li>
    <li>soilMoisture - current soil moisture.</li>
    <li>airTemperature - current air temperature.</li>
    <li>sunlight - current sunlight.</li>
  </ul>
  <br><br>
  <a name="ParrotFlowerPowerset"></a>
  <b>Set</b>
  <ul>
    <li>statusRequest - retrieves the current state of the Parrot Flower Power Sensor.</li>
    <br>
  </ul>
  <br><br>
  <a name="ParrotFlowerPowerattribut"></a>
  <b>Attributes</b>
  <ul>
    <li>disable - disables the Parrot Flower Power device</li>
    <li>disabledForIntervals - disables the Parrot Flower Power device for an interval (example: 00:00-06:00)</li>
    <li>interval - interval in seconds for statusRequest (default: 3600s)</li>
    <li>hciDevice - bluetooth device (default: hci0)</li>
    <br>
  </ul>
</ul>

=end html
=begin html_DE

<a name="ParrotFlowerPower"></a>
<h3>Parrot Flower Power</h3>
<ul>
  <u><b>ParrotFlowerPower - Liesst Daten von einem Parrot Flower Power Sensor</b></u>
  <br>
  Mit diesem Modul ist es m&ouml;glich Daten von einem Sensor auszulesen und darzustellen.</br>
  Gatttool wird f&uuml;r das Modul ben&ouml;tigt. (apt-get install bluez)
  <br><br>
  <a name="ParrotFlowerPowerdefine"></a>
  <b>Define</b>
  <ul><br>
    <code>define &lt;Name der Pflanze&gt; ParrotFlowerPower &lt;BT-MAC&gt;</code>
    <br><br>
    Example:
    <ul><br>
      <code>define MeinePflanze ParrotFlowerPower C4:7C:8D:62:42:6F</code><br>
    </ul>
    <br>
    Das Kommando erzeugt einen ParrotFlowerPower mit der Bluetooth Mac C4:7C:8D:62:42:6F.<br>
    Nachdem das Ger&auml;t erstellt wurde, werden die Daten des Parrot Flower Power Sensors automatisch ausgelesen.
  </ul>
  <br><br>
  <a name="ParrotFlowerPowerreadings"></a>
  <b>Readings</b>
  <ul>
    <li>state - Status des Parrot Flower Power Sensors oder die Fehlermeldung, wenn eine vorhanden ist.</li>
    <li>deviceName - Name des Parrot Flower Power Sensors.</li>
    <li>deviceColor - Farbe des Parrot Flower Power Sensors.</li>
    <li>battery - Batterie Status (h&auml;ngt ab vom batteryLevel).</li>
    <li>batteryLevel - F&uuml;llstand der Batterie.</li>
    <li>soilMoisture - Bodenfeuchtigkeit.</li>
    <li>airTemperature - Lufttemperatur.</li>
    <li>sunlight - Licht.</li>
  </ul>
  <br><br>
  <a name="ParrotFlowerPowerset"></a>
  <b>Set</b>
  <ul>
    <li>statusRequest - liesst den aktuellen Status des Parrot Flower Power Sensors aus.</li>
    <br>
  </ul>
  <br><br>
  <a name="ParrotFlowerPowerattribut"></a>
  <b>Attributes</b>
  <ul>
    <li>disable - deaktiviert das Parrot Flower Power Ger&auml;t</li>
    <li>disabledForIntervals - deaktiviert das Parrot Flower Power Ger&auml;t f&uuml;r eine bestimmte Zeit (Beispiel: 00:00-06:00)</li>
    <li>interval - Intervall in Sekunden f&uuml;r den statusRequest (Voreinstellung: 3600s)</li>
    <li>hciDevice - Bluetooth Ger&auml;t (Voreinstellung: hci0)</li>
    <br>
  </ul>
</ul>

=end html_DE
=cut
