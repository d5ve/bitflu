package Bitflu::Cron;
####################################################################################################
#
# This file is part of 'Bitflu' - (C) 2006-2007 Adrian Ulrich
#
# Released under the terms of The "Artistic License 2.0".
# http://www.perlfoundation.org/legal/licenses/artistic-2_0.txt
#

use strict;
use constant _BITFLU_APIVERSION  => 20080216;
use constant QUEUE_SCAN          => 23;             # How often we are going to scan the queue
use constant SETTING_AUTOCOMMIT  => '_autocommit';  # Setting to use for AUTOCOMMIT
use constant SETTING_AUTOCANCEL  => '_autocancel';  # Setting to use for AUTOCANCEL
use constant AUTOCANCEL_MINRATIO => '1.0';          # Don't allow autocancel values below this


##########################################################################
# Register this plugin
sub register {
	my($class,$mainclass) = @_;
	my $self = { super   => $mainclass , lastrun => 0, next_autoload_scan => 0, next_queue_scan => 0 };
	bless($self,$class);
	
	my $defopts = { autoload_dir => $mainclass->Configuration->GetValue('workdir').'/autoload', autoload_scan => 300,
	                autocommit => 1, autocancel => 1.5 };
	
	foreach my $funk qw(autoload_dir autoload_scan autocancel autocommit) {
		my $this_value = $mainclass->Configuration->GetValue($funk);
		unless(defined($this_value)) {
			$mainclass->Configuration->SetValue($funk,$defopts->{$funk});
		}
	}
	
	$mainclass->AddRunner($self);
	return $self;
}

##########################################################################
# Register  private commands
sub init {
	my($self) = @_;
	
	unless(-d $self->{super}->Configuration->GetValue('autoload_dir')) {
		$self->info("Creating autoload_dir '".$self->{super}->Configuration->GetValue('autoload_dir')."'");
		mkdir($self->{super}->Configuration->GetValue('autoload_dir')) or $self->panic("Unable to create autoload_dir : $!");
	}
	
	$self->{super}->Admin->RegisterCommand('autoload',   $self, '_Command_Autoload',   "Scan ".$self->{super}->Configuration->GetValue('autoload_dir')." for new files now");
	$self->{super}->Admin->RegisterCommand('autocommit', $self, '_Command_Autocommit', "Turns autocommiting on or off for a given queue id",
	 [ [undef, "Usage: autocommit queue_id get|on|off|restore"],
	   [undef, ""],
	   [undef, "autocommit queue_id get      : Display autocommit configuration of queue_id"],
	   [undef, "autocommit queue_id on       : Forces a commit of queue_id after the download finished"],
	   [undef, "autocommit queue_id off      : Disable autocommit feature for queue_id"],
	   [undef, "autocommit queue_id restore  : Inherit global configuration option 'autocommit' for queue_id"],
	   [undef, "                               (This is the default and just removes the forced on/off option"],
	   [undef, ""],
	   [1    , "What does autocommit do?"],
	   [1    , "When bitflu finishes a download it needs to 'assemble' the downloaded file. This is called a 'commit'."],
	   [1    , "You can start a commit yourself using the 'commit' command but bitflu can also issue this command itself"],
	   [1    , "if autocommit is turned on. Autocommit is enabled per default but if you'd like to disable it per default"],
	   [1,   , "just set the configuration option 'autocommit' to 0 (config set autocommit 0). Setting it to 1 enables it again."],
	   [1,   , "The autocommit can be used to override the global default-setting for specific downloads."],
	 ]);
	 
	$self->{super}->Admin->RegisterCommand('autocancel', $self, '_Command_Autocancel', "Cancel file after reaching given ratio",
	 [ [undef, "Usage: autocancel queue_id get|on ratio|off|restore"],
	   [undef, ""],
	   [undef, "autocancel queue_id get      : Display autocancel configuration of queue_id"],
	   [undef, "autocancel queue_id on ratio : Removes queue_id if it has been committed and reached given ratio. Example: autocancel queue_id on 1.5"],
	   [undef, "autocancel queue_id off      : Disable autocancel feature for queue_id (bitflu won't remove the queue_id itself)"],
	   [undef, "autocancel queue_id restore  : Inherit global configuration option 'autocancel' for queue_id"],
	   [undef, "                               (This is the default and just removes the forced on/off option"],
	   [undef, ""],
	   [1    , "What is autocancel?"],
	   [1    , "Bitflu can stop seeding (uploading) a file itself after reaching a given upload ratio."],
	   [1    , "Per default bitflu will stop seeding files after reaching a ratio of ".$self->{super}->Configuration->GetValue('autocancel')],
	   [1,   , "To adjust this setting for all torrents just set the configuration option 'autocancel' to a new value (set it to 0 to disable the feature)"],
	   [1    , "You can adjust this value per queue_id using the autocancel feature, use 'autocancel queue_id restore' to restore the default value"],
	   [1,   , "NOTE: - Bitflu will only cancel a download itself if it could commit the download without any errors."],
	   [1,   , "        Uncommitted downloads will not get canceled by autocancel. You can force a cancel using the 'cancel' command."],
	   [1,   , "      - Do not set the autocancel ratio to a value below ".AUTOCANCEL_MINRATIO.". Bitflu will ignore it."],
	 ]);
	return 1;
}


##########################################################################
# Run jim, run!
sub run {
	my($self) = @_;
	my $NOW = $self->{super}->Network->GetTime;
	return undef if $NOW == $self->{lastrun};
	
	if($self->{next_autoload_scan} <= $NOW) {
		$self->{next_autoload_scan} = $NOW + $self->{super}->Configuration->GetValue('autoload_scan');
		$self->_AutoloadNewFiles;
	}
	if($self->{next_queue_scan} <= $NOW) {
		$self->{next_queue_scan} = $NOW + QUEUE_SCAN;
		$self->_QueueScan;
	}
}


##########################################################################
# Runs aqueue scan to check if we can commit / cancel something
sub _QueueScan {
	my($self) = @_;
	my $qlist = $self->{super}->Queue->GetQueueList();
	foreach my $type (keys(%$qlist)) {
		foreach my $sid (keys(%{$qlist->{$type}})) {
			my $so    = $self->{super}->Storage->OpenStorage($sid) or $self->panic("Unable to open $sid : $!");
			my $stats = $self->{super}->Queue->GetStats($sid);
			my $ratio = sprintf("%.3f", ($stats->{uploaded_bytes}/(1+$stats->{done_bytes})));
			next if ($stats->{total_chunks} != $stats->{done_chunks}); # Don't touch unfinished downloads
			
			if($self->__autocommit_get($so) && !$so->CommitIsRunning && !$so->CommitFullyDone) {
				# Ok, we can/should autocommit it, nobody is doing it now and nobody has done it before: go!
				$self->{super}->Admin->SendNotify("$sid starting autocommit");
				$self->{super}->Admin->ExecuteCommand('commit', $sid);
			}
			
			if($so->CommitFullyDone && $ratio > AUTOCANCEL_MINRATIO) {
				# -> File has been committed without errors (= complete)
				#    and reached the minimal share-ratio. Let's see if we can cancel it:
				my $autocancel_at = $self->__autocancel_get($so);
				if($autocancel_at && $ratio >= $autocancel_at) {
					$self->{super}->Admin->SendNotify("$sid removed from queue (share ratio $ratio is >= $autocancel_at)");
					$self->{super}->Admin->ExecuteCommand('cancel', $sid);
				}
			}
			
		}
	}
	
}


##########################################################################
# Control per-torrent autocommit feature
sub _Command_Autocommit {
	my($self,@args) = @_;

	my ($sid, $action, $argument) = @args;
	my @MSG                       = ();
	my $NOEXEC                    = '';
	my $so                        = $self->{super}->Storage->OpenStorage($sid);
	
	if($so) {
		if(!defined($action) or $action eq "get") {
			push(@MSG, [1, "$sid: ".($self->__autocommit_get($so) ? "autocommit is enabled" : "autocommit is disabled")]);
		}
		elsif($action eq "on") {
			$self->__autocommit_on($so);
			push(@MSG, [1, "$sid: autocommit enabled"]);
		}
		elsif($action eq "off") {
			$self->__autocommit_off($so);
			push(@MSG, [1, "$sid: autocommit disabled"]);
		}
		elsif($action eq "restore") {
			$self->__autocommit_drop($so);
			push(@MSG, [1, "$sid: autocommit setting uses configuration parameter 'autocommit'"]);
		}
		else {
			push(@MSG, [2, "Invalid subcommand '$action'. (Expected 'on', 'off', 'get' or 'restore')"]);
		}
	}
	else {
		$NOEXEC .= "Usage error, type 'help autocommit' for more information";
	}
	
	
	return({MSG=>\@MSG, SCRAP=>[], NOEXEC=>$NOEXEC});
}

##########################################################################
# Handle autocancel command
sub _Command_Autocancel {
	my($self, @args) = @_;
	
	my ($sid, $action, $argument) = @args;
	my @MSG                       = ();
	my $NOEXEC                    = '';
	my $so                        = $self->{super}->Storage->OpenStorage($sid);
	
	if($so) {
		if(!defined($action) or $action eq "get") {
			my $autocancel = $self->__autocancel_get($so);
			my $txt = ($autocancel == 0 ? "autocancel is disabled" : "canceling after reaching a ratio of $autocancel");
			push(@MSG, [1, "$sid : ".$txt]);
		}
		elsif($action eq "on" && $argument) {
			$self->__autocancel_on($so,$argument);
			push(@MSG, [1, "$sid: autocancel will start after ratio ".$self->__autocancel_get($so)." has been reached"]);
		}
		elsif($action eq "off") {
			$self->__autocancel_off($so);
			push(@MSG, [1, "$sid: autocancel has been disabled"]);
		}
		elsif($action eq "restore") {
			$self->__autocancel_drop($so);
			push(@MSG, [1, "$sid: autocancel setting uses configuration parameter 'autocancel'"]);
		}
		else {
			push(@MSG, [2, "Invalid subcommand '$action'. (Expected 'on', 'off', 'get' or 'restore')"]);
		}
	}
	else {
		$NOEXEC .= "Usage error, type 'help autocancel' for more information";
	}
	
	return({MSG=>\@MSG, SCRAP=>[], NOEXEC=>$NOEXEC});
}

##########################################################################
# Returns configsetting if sid doesn't have an autocommit value
# return 0      if forced of, otherwise true is returned
sub __autocommit_get {
	my($self,$so) = @_;
	my $setting = $so->GetSetting(SETTING_AUTOCOMMIT);
	return $self->{super}->Configuration->GetValue('autocommit') if (!defined($setting) or $setting == 0);
	return 0     if $setting <  0;
	return 1;
}
sub __autocommit_on   { my($self,$so,$v) = @_; $so->SetSetting(SETTING_AUTOCOMMIT, int($v))  }
sub __autocommit_off  { my($self,$so) = @_;    $so->SetSetting(SETTING_AUTOCOMMIT, -1)       }
sub __autocommit_drop { my($self,$so) = @_;    $so->SetSetting(SETTING_AUTOCOMMIT, 0)        }


##########################################################################
# Returns configsetting if sid doesn't have an autocancel value
# return 0      if forced of, otherwise true is returned
sub __autocancel_get {
	my($self,$so) = @_;
	my $setting = $so->GetSetting(SETTING_AUTOCANCEL);
	return $self->{super}->Configuration->GetValue('autocancel') if (!defined($setting) or $setting == 0);
	return 0     if $setting <  0;
	return $setting;
}
sub __autocancel_on   { my($self,$so,$v) = @_; $so->SetSetting(SETTING_AUTOCANCEL, abs(sprintf("%.3f",$v))) }
sub __autocancel_off  { my($self,$so) = @_;    $so->SetSetting(SETTING_AUTOCANCEL, -1)                      }
sub __autocancel_drop { my($self,$so) = @_;    $so->SetSetting(SETTING_AUTOCANCEL, 0)                       }



##########################################################################
# Kick autoloader
sub _Command_Autoload {
	my($self) = @_;
	$self->{next_autoload_scan} = 0;
	return({MSG=>[[1, "Autoloading files from ".$self->{super}->Configuration->GetValue('autoload_dir')]], SCRAP=>[]});
}


##########################################################################
# Starts scanning the autoload folder and picksup new files
sub _AutoloadNewFiles {
	my($self) = @_;
	
	$self->debug("Scanning autoload directory '".$self->{super}->Configuration->GetValue('autoload_dir')."' for new downloads");
	if( opendir(ALH, $self->{super}->Configuration->GetValue('autoload_dir')) ) {
		while(defined(my $dirent = readdir(ALH))) {
			$dirent = $self->{super}->Configuration->GetValue('autoload_dir')."/$dirent";
			next unless -f $dirent;
			my $exe = $self->{super}->Admin->ExecuteCommand('load',$dirent);
			if($exe->{FAILS} == 0) {
				$self->info("Autoloaded '$dirent'");
				unlink($dirent) or $self->warn("Unable to remove $dirent : $!");
			}
			else {
				$self->warn("Unable to autoload file '$dirent'. Please remove this file");
			}
		}
		closedir(ALH) or $self->panic("Unable to close dir we just opened: $!");
	}
	else {
		$self->warn("Unable to open autoload_dir '".$self->{super}->Configuration->GetValue('autoload_dir')."' : $!");
	}
}






sub debug { my($self, $msg) = @_; $self->{super}->debug(ref($self)."[Cron]: ".$msg); }
sub info  { my($self, $msg) = @_; $self->{super}->info(ref($self)." [Cron]: ".$msg);  }
sub warn  { my($self, $msg) = @_; $self->{super}->warn(ref($self)." [Cron]: ".$msg);  }
sub panic { my($self, $msg) = @_; $self->{super}->panic(ref($self)."[Cron]: ".$msg); }



1;
