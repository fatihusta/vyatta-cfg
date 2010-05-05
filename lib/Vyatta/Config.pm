# Author: An-Cheng Huang <ancheng@vyatta.com>
# Date: 2007
# Description: vyatta configuration parser

# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
# 
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2006, 2007, 2008 Vyatta, Inc.
# All Rights Reserved.
# **** End License ****

package Vyatta::Config;

use strict;

use Vyatta::ConfigDOMTree;

my %fields = (
  _changes_only_dir_base  => $ENV{VYATTA_CHANGES_ONLY_DIR},
  _new_config_dir_base    => $ENV{VYATTA_TEMP_CONFIG_DIR},
  _active_dir_base        => $ENV{VYATTA_ACTIVE_CONFIGURATION_DIR},
  _vyatta_template_dir    => $ENV{VYATTA_CONFIG_TEMPLATE},
  _current_dir_level      => "/",
  _level => undef,
);

sub new {
  my $that = shift;
  my $class = ref ($that) || $that;
  my $self = {
    %fields,
  };

  bless $self, $class;
  return $self;
}

sub _set_current_dir_level {
  my ($self) = @_;
  my $level = $self->{_level};

  $level =~ s/\//%2F/g;
  $level =~ s/\s+/\//g;

  $self->{_current_dir_level} = "/$level";
  return $self->{_current_dir_level};
}

## setLevel("level")
# if "level" is supplied, set the current level of the hierarchy we are working on
# return the current level
sub setLevel {
  my ($self, $level) = @_;

  $self->{_level} = $level if defined($level);
  $self->_set_current_dir_level();

  return $self->{_level};
}

## listNodes("level")
# return array of all nodes at "level"
# level is relative
sub listNodes {
  my ($self, $path) = @_;
  my @nodes = ();

  if ($path) { 
    $path =~ s/\//%2F/g;
    $path =~ s/\s+/\//g;
    $path = $self->{_new_config_dir_base} . $self->{_current_dir_level} . "/" . $path;
  }  else {
    $path = $self->{_new_config_dir_base} . $self->{_current_dir_level};
  }

  #print "DEBUG Vyatta::Config->listNodes(): path = $path\n";
  opendir my $dir, $path or return ();
  @nodes = grep !/^\./, readdir $dir;
  closedir $dir;

  my @nodes_modified = ();
  while (@nodes) {
    my $tmp = pop (@nodes);
    $tmp =~ s/\n//g;
    $tmp =~ s/%2F/\//g;
    #print "DEBUG Vyatta::Config->listNodes(): node = $tmp\n";
    push @nodes_modified, $tmp;
  }

  return @nodes_modified;
}

## isActive("path")
# return true|false based on whether node path has
# been processed or is active
sub isActive {
  my ($self, $path) = @_;  
  my @nodes = ();

  my @comp_node = split " ", $path;

  my $comp_node = pop(@comp_node);
  if (!defined $comp_node) {
      return 1;
  }
  
  my $rel_path = join(" ",@comp_node);

  my @nodes_modified = $self->listOrigPlusComNodes($rel_path);
  foreach my $node (@nodes_modified) {
      if ($node eq $comp_node) {
	  return 0;
      }
  }
  return 1;
}

## listNodes("level")
# return array of all nodes (active plus currently committed) at "level"
# level is relative
sub listOrigPlusComNodes {
  my ($self, $path) = @_;
  my @nodes = ();

  my @nodes_modified = $self->listNodes($path);

  #convert array to hash
  my %coll;
  my $coll;
  @coll{@nodes_modified} = @nodes_modified;

  my $level = $self->{_level};
  if (! defined $level) {
      $level = "";
  }

  my $dir_path = $level;
  if (defined $path) {
      $dir_path .= " " . $path;
  }
  $dir_path =~ s/ /\//g;
  $dir_path = "/".$dir_path;

  #now test against the inprocess file in the system
#  my $com_file = "/tmp/.changes_$$";
  my $com_file = "/tmp/.changes";
  if (-e $com_file) {
      open my $file, "<", $com_file;
      foreach my $line (<$file>) {
	  my @node = split " ", $line; #split on space
	  #$node[1] is of the form: system/login/blah
	  #$coll is of the form: blah

#	  print("comparing: $dir_path and $level to $node[1]\n");

	  #first only consider $path matches against $node[1]
	  if (!defined $dir_path || $node[1] =~ m/^$dir_path/) {
	      #or does $node[1] match the beginning of the line for $path
	      
	      #if yes, then split the right side and find against the hash for the value...
	      my $tmp;
	      if (defined $dir_path) {
		  $tmp = substr($node[1],length($dir_path));
	      }
	      else {
		  $tmp = $node[1];
	      }
	      
	      if (!defined $tmp || $tmp eq '') {
		  next;
	      }

	      my @child = split "/",$tmp;
	      my $child;

#	      print("tmp: $tmp, $child[0], $child[1]\n");
	      if ($child[0] =~ /^\s*$/ || !defined $child[0] || $child[0] eq '') {
		  shift(@child);
	      }

#	      print("child value is: >$child[0]<\n");

	      #now can we find this entry in the hash?
	      #if '-' this is a delete and need to remove from hash
	      if ($node[0] eq "-") {
		  if (!defined $child[1]) {
		      delete($coll{$child[0]});
		  }
	      }
	      #if '+' this is a set and need to add to hash
	      elsif ($node[0] eq "+" && $child[0] ne '') {
		  $coll{$child[0]} = '1';
	      }
	  }
      }
      close $file;
      close $com_file;
  }

#print "coll count: ".keys(%coll);

  #now convert hash to array and return
  @nodes_modified = ();
  @nodes_modified = keys(%coll);
  return @nodes_modified;
}

## listOrigNodes("level")
# return array of all original nodes (i.e., before any current change; i.e.,
# in "working") at "level"
# level is relative
sub listOrigNodes {
  my ($self, $path) = @_;
  my @nodes = ();

  if (defined $path) { 
    $path =~ s/\//%2F/g;
    $path =~ s/\s+/\//g;
    $path = $self->{_active_dir_base} . $self->{_current_dir_level} . "/"
            . $path;
  }
  else {
    $path = $self->{_active_dir_base} . $self->{_current_dir_level};
  }

  #print "DEBUG Vyatta::Config->listNodes(): path = $path\n";
  opendir my $dir, "$path" or return ();
  @nodes = grep !/^\./, readdir $dir;
  closedir $dir;

  my @nodes_modified = ();
  while (@nodes) {
    my $tmp = pop (@nodes);
    $tmp =~ s/\n//g;
    $tmp =~ s/%2F/\//g;
    #print "DEBUG Vyatta::Config->listNodes(): node = $tmp\n";
    push @nodes_modified, $tmp;
  }

  return @nodes_modified;
}

## listOrigNodes("level")
# return array of all original nodes (i.e., before any current change; i.e.,
# in "working") at "level"
# level is relative
sub listOrigNodesNoDef {
  my ($self, $path) = @_;
  my @nodes = ();

  if (defined $path) { 
    $path =~ s/\//%2F/g;
    $path =~ s/\s+/\//g;
    $path = $self->{_active_dir_base} . $self->{_current_dir_level} . "/"
            . $path;
  }
  else {
    $path = $self->{_active_dir_base} . $self->{_current_dir_level};
  }

  #print "DEBUG Vyatta::Config->listNodes(): path = $path\n";
  opendir my $dir, $path or return ();
  @nodes = grep !/^\./, readdir $dir;
  closedir $dir;

  my @nodes_modified = ();
  while (@nodes) {
    my $tmp = pop (@nodes);
    $tmp =~ s/\n//g;
    $tmp =~ s/%2F/\//g;
    #print "DEBUG Vyatta::Config->listNodes(): node = $tmp\n";
    if ($tmp ne 'def') {
	push @nodes_modified, $tmp;
    }
  }

  return @nodes_modified;
}

## returnParent("level")
# return the name of parent node relative to the current hierarchy
# in this case "level" is set to the parent dir ".. .."
# for example
sub returnParent {
  my ($self, $node) = @_;
  my @x, my $tmp;

  # split our hierarchy into vars on a stack
  my @level = split /\s+/, $self->{_level};

  # count the number of parents we need to lose
  # and then pop 1 less
  @x = split /\s+/, $node;
  for ($tmp = 1; $tmp < @x; $tmp++) {
    pop @level;
  }

  # return the parent
  $tmp = pop @level;
  return $tmp;
}

## returnValue("node")
# returns the value of "node" or undef if the node doesn't exist .
# node is relative
sub returnValue {
  my ( $self, $node ) = @_;
  my $tmp;

  $node =~ s/\//%2F/g;
  $node =~ s/\s+/\//g;

  return unless 
      open my $file, '<', 
      "$self->{_new_config_dir_base}$self->{_current_dir_level}/$node/node.val";

  read $file, $tmp, 16384;
  close $file;

  $tmp =~ s/\n$//;
  return $tmp;
}

## returnOrigPlusComValue("node")
# returns the value of "node" or undef if the node doesn't exist .
# node is relative
sub returnOrigPlusComValue {
  my ( $self, $path ) = @_;

  my $tmp = returnValue($self,$path);

  my $level = $self->{_level};
  if (! defined $level) {
      $level = "";
  }
  my $dir_path = $level;
  if (defined $path) {
      $dir_path .= " " . $path;
  }
  $dir_path =~ s/ /\//g;
  $dir_path = "/".$dir_path."/value";

  #now need to compare this against what I've done
  my $com_file = "/tmp/.changes";
  if (-e $com_file) {
      open my $file, "<", $com_file;
      foreach my $line (<$file>) {
	  my @node = split " ", $line; #split on space
	  if (index($node[1],$dir_path) != -1) {
	      #found, now figure out if this a set or delete
	      if ($node[0] eq '+') {
		  my $pos = rindex($node[1],"/value:");
		  $tmp = substr($node[1],$pos+7);
	      }
	      else {
		  $tmp = "";
	      }
	      last;
	  }
      }
      close $file;
      close $com_file;
  }
  return $tmp;
}


## returnOrigValue("node")
# returns the original value of "node" (i.e., before the current change; i.e.,
# in "working") or undef if the node doesn't exist.
# node is relative
sub returnOrigValue {
  my ( $self, $node ) = @_;
  my $tmp;

  $node =~ s/\//%2F/g;
  $node =~ s/\s+/\//g;
  my $filepath = "$self->{_active_dir_base}$self->{_current_dir_level}/$node";

  return unless open my $file, '<', "$filepath/node.val";
  
  read $file, $tmp, 16384;
  close $file;

  $tmp =~ s/\n$//;
  return $tmp;
}

## returnValues("node")
# returns an array of all the values of "node", or an empty array if the values do not exist.
# node is relative
sub returnValues {
  my $val = returnValue(@_);
  my @values = ();
  if (defined($val)) {
    @values = split("\n", $val);
  }
  return @values;
}

## returnValues("node")
# returns an array of all the values of "node", or an empty array if the values do not exist.
# node is relative
sub returnOrigPlusComValues {
  my ( $self, $path ) = @_;
  my @values = returnOrigValues($self,$path);

  #now parse the commit accounting file.
  my $level = $self->{_level};
  if (! defined $level) {
      $level = "";
  }
  my $dir_path = $level;
  if (defined $path) {
      $dir_path .= " " . $path;
  }
  $dir_path =~ s/ /\//g;
  $dir_path = "/".$dir_path."/value";

  #now need to compare this against what I've done
  my $com_file = "/tmp/.changes";
  if (-e $com_file) {
      open my $file, "<", $com_file;
      foreach my $line (<$file>) {
	  my @node = split " ", $line; #split on space
	  if (index($node[1],$dir_path) != -1) {
	      #found, now figure out if this a set or delete
	      my $pos = rindex($node[1],"/value:");
	      my $tmp = substr($node[1],$pos+7);
	      my $i = 0;
	      my $match = 0;
	      foreach my $v (@values) {
		  if ($v eq $tmp) {
		      $match = 1;
		      last;
		  }
		  $i = $i + 1;
	      }
	      if ($node[0] eq '+') {
		  #add value
		  if ($match == 0) {
		      push(@values,$tmp);
		  }
	      }
	      else {
		  #remove value
		  if ($match == 1) {
		      splice(@values,$i);
		  }
	      }
	  }
      }
      close $file;
      close $com_file;
  }
  return @values;
}

## returnOrigValues("node")
# returns an array of all the original values of "node" (i.e., before the
# current change; i.e., in "working"), or an empty array if the values do not
# exist.
# node is relative
sub returnOrigValues {
  my $val = returnOrigValue(@_);
  my @values = ();
  if (defined($val)) {
   @values = split("\n", $val);
  }
  return @values;
}

## exists("node")
# Returns true if the "node" exists. 
sub exists {
  my ( $self, $node ) = @_;
  $node =~ s/\//%2F/g;
  $node =~ s/\s+/\//g;

  return ( -d "$self->{_new_config_dir_base}$self->{_current_dir_level}/$node" );
}

## existsOrig("node")
# Returns true if the "original node" exists. 
sub existsOrig {
  my ( $self, $node ) = @_;
  $node =~ s/\//%2F/g;
  $node =~ s/\s+/\//g;

  return ( -d "$self->{_active_dir_base}$self->{_current_dir_level}/$node" );
}

## isDeleted("node")
# is the "node" deleted. node is relative.  returns true or false
sub isDeleted {
  my ($self, $node) = @_;
  $node =~ s/\//%2F/g;
  $node =~ s/\s+/\//g;

  my $filepathAct
    = "$self->{_active_dir_base}$self->{_current_dir_level}/$node";
  my $filepathNew
    = "$self->{_new_config_dir_base}$self->{_current_dir_level}/$node";

  return ((-e $filepathAct) && !(-e $filepathNew));
}

## listDeleted("level")
# return array of deleted nodes in the "level"
# "level" defaults to current
sub listDeleted {
  my ($self, $path) = @_;
  my @new_nodes = $self->listNodes($path);
  my @orig_nodes = $self->listOrigNodes($path);
  my %new_hash = map { $_ => 1 } @new_nodes;
  my @deleted = grep { !defined($new_hash{$_}) } @orig_nodes;
  return @deleted;
}

## isDeactivated("node")
# returns back whether this node is in an active (false) or
# deactivated (true) state.
sub getDeactivated {
  my ($self, $node) = @_;

  if (!defined $node) {
  }

  # let's setup the filepath for the change_dir
  $node =~ s/\//%2F/g;
  $node =~ s/\s+/\//g;
  #now walk up parent in local and in active looking for '.disable' file

  my @a = split(" ",$node);
  $node = join("/",@a);

  while (1) {
      my $filepath = "$self->{_changes_only_dir_base}/$node";
      my $filepathActive = "$self->{_active_dir_base}/$node";

      my $local = $filepath . "/.disable";
      my $active = $filepathActive . "/.disable";
      
      if (-e $local && -e $active) {
	  return ("both",$node);
      }
      elsif (-e $local && !(-e $active)) {
	  return ("local",$node);
      }
      elsif (!(-e $local) && -e $active) {
	  return ("active",$node);
      }
      my $pos = rindex($node, "/");
      if ($pos == -1) {
	  last;
      }
      $node = substr($node,0,$pos);
  }
  return (undef,undef);
}

## isChanged("node")
# will check the change_dir to see if the "node" has been changed from a previous
# value.  returns true or false.
sub isChanged {
  my ($self, $node) = @_;

  # let's setup the filepath for the change_dir
  $node =~ s/\//%2F/g;
  $node =~ s/\s+/\//g;
  my $filepath = "$self->{_changes_only_dir_base}$self->{_current_dir_level}/$node";

  # if the node exists in the change dir, it's modified.
  return (-e $filepath);
}

## isChangedOrDeleted("node")
# is the "node" changed or deleted. node is relative.  returns true or false
sub isChangedOrDeleted {
  my ($self, $node) = @_;

  $node =~ s/\//%2F/g;
  $node =~ s/\s+/\//g;

  my $filepathChg
    = "$self->{_changes_only_dir_base}$self->{_current_dir_level}/$node";
  if (-e $filepathChg) {
    return 1;
  }

  my $filepathAct
    = "$self->{_active_dir_base}$self->{_current_dir_level}/$node";
  my $filepathNew
    = "$self->{_new_config_dir_base}$self->{_current_dir_level}/$node";

  return ((-e $filepathAct) && !(-e $filepathNew));
}

## isAdded("node")
# will compare the new_config_dir to the active_dir to see if the "node" has 
# been added.  returns true or false.
sub isAdded {
  my ($self, $node) = @_;

  #print "DEBUG Vyatta::Config->isAdded(): node $node\n";
  # let's setup the filepath for the modify dir
  $node =~ s/\//%2F/g;
  $node =~ s/\s+/\//g;
  my $filepathNewConfig = "$self->{_new_config_dir_base}$self->{_current_dir_level}/$node";
  
  #print "DEBUG Vyatta::Config->isAdded(): filepath $filepathNewConfig\n";

  # if the node doesn't exist in the modify dir, it's not
  # been added.  so short circuit and return false.
  return unless (-e $filepathNewConfig);
 
  # now let's setup the path for the working dir
  my $filepathActive = "$self->{_active_dir_base}$self->{_current_dir_level}/$node";

  # if the node is in the active_dir it's not new
  return (! -e $filepathActive);
}

## listNodeStatus("level")
# return a hash of the status of nodes at the current config level
# node name is the hash key. node status is the hash value.
# node status can be one of deleted, added, changed, or static
sub listNodeStatus {
  my ($self, $path) = @_;
  my @nodes = ();
  my %nodehash = ();

  # find deleted nodes first
  @nodes = $self->listDeleted($path);
  foreach my $node (@nodes) {
    if ($node =~ /.+/) { $nodehash{$node} = "deleted" };
  }

  @nodes = ();
  @nodes = $self->listNodes($path);
  foreach my $node (@nodes) {
    if ($node =~ /.+/) {
	my $nodepath = $node;
	$nodepath = "$path $node" if ($path);
	#print "DEBUG Vyatta::Config->listNodeStatus(): node $node\n";
	# No deleted nodes -- added, changed, ot static only.
	if    ($self->isAdded($nodepath))   { $nodehash{$node} = "added"; }
	elsif ($self->isChanged($nodepath)) { $nodehash{$node} = "changed"; }
	else { $nodehash{$node} = "static"; }
    }
  }

  return %nodehash;
}

############ DOM Tree ################

#Create active DOM Tree
sub createActiveDOMTree {

    my $self = shift;

    my $tree = new Vyatta::ConfigDOMTree($self->{_active_dir_base} . $self->{_current_dir_level},"active");

    return $tree;
}

#Create changes only DOM Tree
sub createChangesOnlyDOMTree {

    my $self = shift;

    my $tree = new Vyatta::ConfigDOMTree($self->{_changes_only_dir_base} . $self->{_current_dir_level},
				       "changes_only");

    return $tree;
}

#Create new config DOM Tree
sub createNewConfigDOMTree {

    my $self = shift;
    my $level = $self->{_new_config_dir_base} . $self->{_current_dir_level};

    return new Vyatta::ConfigDOMTree($level, "new_config");
}


###### functions for templates ######

# $1: array representing the config node path.
# returns the filesystem path to the template of the specified node,
#   or undef if the specified node path is not valid.
sub getTmplPath {
  my $self = shift;
  my @cfg_path = @{$_[0]};
  my $tpath = $self->{_vyatta_template_dir};
  for my $p (@cfg_path) {
    if (-d "$tpath/$p") {
      $tpath .= "/$p";
      next;
    }
    if (-d "$tpath/node.tag") {
      $tpath .= "/node.tag";
      next;
    }
    # the path is not valid!
    return;
  }
  return $tpath;
}

sub isTagNode {
  my $self = shift;
  my $cfg_path_ref = shift;
  my $tpath = $self->getTmplPath($cfg_path_ref);
  return unless $tpath;

  return (-d "$tpath/node.tag");
}

sub hasTmplChildren {
  my $self = shift;
  my $cfg_path_ref = shift;
  my $tpath = $self->getTmplPath($cfg_path_ref);
  return unless $tpath;

  opendir (my $tdir, $tpath) or return;
  my @tchildren = grep !/^node\.def$/, (grep !/^\./, (readdir $tdir));
  closedir $tdir;

  return (scalar(@tchildren) > 0);
}

# $cfg_path_ref: ref to array containing the node path.
# returns ($is_multi, $is_text, $default),
#   or undef if specified node is not valid.
sub parseTmpl {
  my $self = shift;
  my $cfg_path_ref = shift;
  my ($is_multi, $is_text, $default) = (0, 0, undef);
  my $tpath = $self->getTmplPath($cfg_path_ref);
  return unless $tpath;

  if (! -r "$tpath/node.def") {
    return ($is_multi, $is_text);
  }

  open (my $tmpl, '<', "$tpath/node.def")
      or return ($is_multi, $is_text);
  foreach (<$tmpl>) {
    if (/^multi:/) {
      $is_multi = 1;
    }
    if (/^type:\s+txt\s*$/) {
      $is_text = 1;
    }
    if (/^default:\s+(\S+)\s*$/) {
      $default = $1;
    }
  }
  close $tmpl;
  return ($is_multi, $is_text, $default);
}

# $cfg_path: config path of the node.
# returns a hash ref containing attributes in the template
#   or undef if specified node is not valid.
sub parseTmplAll {
  my ($self, $cfg_path) = @_;
  my @pdirs = split(/ +/, $cfg_path);
  my %ret = ();
  my $tpath = $self->getTmplPath(\@pdirs);
  return unless $tpath;

  open(my $tmpl, '<', "$tpath/node.def") 
	or return;
  foreach (<$tmpl>) {
    if (/^multi:\s*(\S+)?$/) {
	$ret{multi} = 1;
	$ret{limit} = $1;
    } elsif (/^tag:\s*(\S+)?$/) {
	$ret{tag} = 1;
	$ret{limit} = $1;
    } elsif (/^type:\s+(\S+),\s*(\S+)\s*$/) {
	$ret{type} = $1;
	$ret{type2} = $2;
    } elsif (/^type:\s+(\S+)\s*$/) {
	$ret{type} = $1;
    } elsif (/^default:\s+(\S.*)\s*$/) {
	$ret{default} = $1;
	if ($ret{default} =~ /^"(.*)"$/) {
	    $ret{default} = $1;
	}
    } elsif (/^help:\s+(\S.*)$/) {
	$ret{help} = $1;
    }
  }
  close($tmpl);
  return \%ret;
}

# $cfg_path: config path of the node.
# returns the list of the node's children in the template hierarchy.
sub getTmplChildren {
  my ($self, $cfg_path) = @_;
  my @pdirs = split(/ +/, $cfg_path);
  my $tpath = $self->getTmplPath(\@pdirs);
  return () unless $tpath;

  opendir (my $tdir, $tpath) or return;
  my @tchildren = grep !/^node\.def$/, (grep !/^\./, (readdir $tdir));
  closedir $tdir;

  return @tchildren;
}

###### misc functions ######

# compare two value lists and return "deleted" and "added" lists.
# since this is for multi-value nodes, there is no "changed" (if a value's
# ordering changed, it is deleted then added).
# $0: \@orig_values
# $1: \@new_values
sub compareValueLists {
  my $self = shift;
  my @ovals = @{$_[0]};
  my @nvals = @{$_[1]};
  my %comp_hash = (
                    'deleted' => [],
                    'added' => [],
                  );
  my $idx = 0;
  my %ohash = map { $_ => ($idx++) } @ovals;
  $idx = 0;
  my %nhash = map { $_ => ($idx++) } @nvals;
  my $min_changed_idx = 2**31;
  my %dhash = ();
  foreach (@ovals) {
    if (!defined($nhash{$_})) {
      push @{$comp_hash{'deleted'}}, $_;
      $dhash{$_} = 1;
      if ($ohash{$_} < $min_changed_idx) {
        $min_changed_idx = $ohash{$_};
      }
    }
  }
  foreach (@nvals) {
    if (defined($ohash{$_})) {
      if ($ohash{$_} != $nhash{$_}) {
        if ($ohash{$_} < $min_changed_idx) {
          $min_changed_idx = $ohash{$_};
        }
      }
    }
  }
  foreach (@nvals) {
    if (defined($ohash{$_})) {
      if ($ohash{$_} != $nhash{$_}) {
        if (!defined($dhash{$_})) {
          push @{$comp_hash{'deleted'}}, $_;
          $dhash{$_} = 1;
        }
        push @{$comp_hash{'added'}}, $_;
      } elsif ($ohash{$_} >= $min_changed_idx) {
        # ordering unchanged, but something before it is changed.
        if (!defined($dhash{$_})) {
          push @{$comp_hash{'deleted'}}, $_;
          $dhash{$_} = 1;
        }
        push @{$comp_hash{'added'}}, $_;
      } else {
        # this is before any changed value. do nothing.
      }
    } else {
      push @{$comp_hash{'added'}}, $_;
    }
  }
  return %comp_hash;
}

1;
