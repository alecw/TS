#!/usr/bin/env perl
# Copyright (C) 2010 Ion Torrent Systems, Inc. All Rights Reserved

use strict;
use warnings;
use POSIX;
use File::Basename;
use Getopt::Long;

my $opt = {
  "readFile"               => undef,
  "readFileBase"           => undef,
  "readFileType"           => undef,
  "genome"                 => undef,
  "filter-length"          => undef,
  "out-base-name"          => undef,
  "trim-length"            => undef,
  "start-slop"             => 0,
  "sample-size"            => 0,
  "max-plot-read-len"      => 400,
  "qscores"                => "7,10,17,20,47",
  "threads"                => &numCores(),
  "aligner"                => "tmap",
  "aligner-opts-rg"        => undef,                 # primary options (for -R to TMAP)
  "aligner-opts-extra"     => "stage1 --stage-seed-freq-cutoff 0.1 map1 map2 map3", # this could include stage and algorithm options
  "aligner-format-version" => undef,
  "align-all-reads"        => 0,
  "genome-path"            => ["/referenceLibrary","/results/referenceLibrary","/opt/ion/referenceLibrary"],
  "sam-parsed"             => 0,
  "realign"                => 0,
  "help"                   => 0,
  "default-sample-size"    => 10000,
  "default-exclude-length" => 20,
  "logfile"                => "alignmentQC_out.txt",
  "output-dir"             => "./",
};

GetOptions(
  "i|input=s"                => \$opt->{"readFile"},
  "g|genome=s"               => \$opt->{"genome"},
  "o|out-base-name=s"        => \$opt->{"out-base-name"},
  "t|trim-length=i"          => \$opt->{"trim-length"},
  "s|start-slop=i"           => \$opt->{"start-slop"},
  "n|sample-size=i"          => \$opt->{"sample-size"},
  "l|filter-length=i"        => \$opt->{"filter-length"},
  "m|max-plot-read-len=s"    => \$opt->{"max-plot-read-len"},
  "q|qscores=s"              => \$opt->{"qscores"},
  "b|threads=i"              => \$opt->{"threads"},
  "d|aligner=s"              => \$opt->{"aligner"},
  "aligner-opts-rg=s"        => \$opt->{"aligner-opts-rg"},
  "aligner-opts-extra=s"     => \$opt->{"aligner-opts-extra"},
  "c|align-all-reads"        => \$opt->{"align-all-reads"},
  "a|genome-path=s@"         => \$opt->{"genome-path"},
  "p|sam-parsed"             => \$opt->{"sam-parsed"},
  "r|realign"                => \$opt->{"realign"},
  "aligner-format-version=s" => \$opt->{"aligner-format-version"},
  "h|help"                   => \$opt->{"help"},
  "output-dir=s"             => \$opt->{"output-dir"},
  "logfile=s"                => \$opt->{"logfile"},
);

&checkArgs($opt);

unlink($opt->{"logfile"}) if(-e $opt->{"logfile"});

# Determine how many reads are being aligned, make sure there is at least one
my $nReads = &getReadNumber($opt->{"readFile"},$opt->{"readFileType"});
if($nReads==0) {
  print STDERR "WARNING: $0: no reads to align in ".$opt->{"readFile"}."\n";
  #exit(0);
}
print "Aligning $nReads reads from ".$opt->{"readFile"}."\n";


# Find the location of the genome index
my $indexVersion = defined($opt->{"aligner-format-version"}) ? $opt->{"aligner-format-version"} : &getIndexVersion();
my($refDir,$refInfo,$refFasta,$infoFile) = &findReference($opt->{"genome-path"},$opt->{"genome"},$opt->{"aligner"},$indexVersion);
print "Aligning to reference genome in $refDir\n";


# If out base name was not specified then derive from the base name of the input file
$opt->{"out-base-name"} = $opt->{"readFileBase"} if(!defined($opt->{"out-base-name"}));

# If not specifying that all reads be aligned, if sample size is not set via command-line and if the genome
# info file has a specification, then set sampling according to it.
if((!$opt->{"align-all-reads"}) && ($opt->{"sample-size"} == 0) && exists($refInfo->{"read_sample_size"})) {
  $opt->{"sample-size"} = $refInfo->{"read_sample_size"};
}


# Implement random sampling, so long as align-all-reads has not been specified
if($opt->{"sample-size"} > 0) {
  if($opt->{"align-all-reads"}) {
    print "Request for sampling overridden by request to align all reads\n";
  } elsif($opt->{"sample-size"} >= $nReads) {
    print "Sample size is greater than number of reads, aligning everything\n";
    $opt->{"sample-size"} = 0;
  } else {
    die "$0: sampling is only possible when input file is in sff format\n" if($opt->{"readFileType"} ne "sff");
    print "Aligning random sample of ".$opt->{"sample-size"}." from total of $nReads reads\n";
    my $sampledSff   = &extendSuffix($opt->{"readFile"},"sff","sampled");

    my $command1 = sprintf("SFFRandom -n %s -o %s %s 2>>%s",$opt->{"sample-size"},$sampledSff,$opt->{"readFile"},$opt->{"logfile"});
    die "$0: Failure during random sampling of reads\n" if(&executeSystemCall($command1));

    $opt->{"readFile"} = $sampledSff;
  }
}


# Set the min length of alignments to retain if it wasn't specified on command line
if(!defined($opt->{"filter-length"})) {
  $opt->{"filter-length"} = exists($refInfo->{"read_exclude_length"}) ?  $refInfo->{"read_exclude_length"} : $opt->{"default-exclude-length"};
}


# Truncate reads, if requested
my $truncatedFile = undef;
if(defined($opt->{"trim-length"})) {
  $truncatedFile = &extendSuffix($opt->{"readFile"},$opt->{"readFileType"},"truncated");
  if($opt->{"readFileType"} eq "fastq") {
    my $commandTrim = sprintf("trimfastq.pl -i %s -o %s -l %s 2>>%s",$opt->{"readFile"},$truncatedFile,$opt->{"trim-length"},$opt->{"logfile"});
    die "$0: Failure during truncation of reads\n" if(&executeSystemCall($commandTrim));
  } else {
    die "$0: don't know how to truncate reads of format ".$opt->{"readFileType"}."\n";
  }
}


# Do the alignment
my $fileToAlign = defined($opt->{"trim-length"}) ? $truncatedFile : $opt->{"readFile"};
my $bamBase = $opt->{"output-dir"} . "/" . basename($opt->{"out-base-name"});
my $bamFile = $bamBase.".bam";
my $alignStartTime = time();
if($opt->{"aligner"} eq "tmap") {
  my $command = "tmap mapall";
  $command .= " -n ".$opt->{"threads"};
  $command .= " -f $refFasta";
  $command .= " -r $fileToAlign";
  $command .= " -Y";
  $command .= " -v";
  $command .= " ".$opt->{"aligner-opts-rg"} if(defined($opt->{"aligner-opts-rg"}));
  die if(!defined($opt->{"aligner-opts-extra"}));
  $command .= " ".$opt->{"aligner-opts-extra"};
  $command .= " 2>> ".$opt->{"logfile"};
  $command .= " | samtools view -Sbu - | samtools sort -m 1000000000 - $bamBase";
  print "  $command\n";
  die "$0: Failure during read mapping\n" if(&executeSystemCall($command));
} else {
  die "$0: invalid aligner option: ".$opt->{"aligner"}."\n";
}
die "$0: Failure during bam indexing\n" if(&executeSystemCall("samtools index $bamFile"));

my $alignStopTime = time();
my $alignTime = &ceil(($alignStopTime-$alignStartTime)/60);
print "Alignment time: $alignTime minutes\n";

# Alignment post-processing
my $postAlignStartTime = time();
my $commandPostProcess = "alignStats";
$commandPostProcess .= " -i $bamFile";
$commandPostProcess .= " -g $infoFile";
$commandPostProcess .= " -n ".$opt->{"threads"};
$commandPostProcess .= " -l ".$opt->{"filter-length"};
$commandPostProcess .= " -m ".$opt->{"max-plot-read-len"};
$commandPostProcess .= " -q ".$opt->{"qscores"};
$commandPostProcess .= " -s ".$opt->{"start-slop"};
$commandPostProcess .= " -a alignTable.txt";
$commandPostProcess .= " -p 1" if($opt->{"sam-parsed"});
if($opt->{"sample-size"}) {
  $commandPostProcess .= " --totalReads $nReads";
  $commandPostProcess .= " --sampleSize ".$opt->{"sample-size"};
}
if($opt->{"output-dir"}) {
  $commandPostProcess .= " --outputDir ".$opt->{"output-dir"};
}
$commandPostProcess .= " 2>> ".$opt->{"logfile"};
print "  $commandPostProcess\n";
die "$0: Failure during alignment post-processing\n" if(&executeSystemCall($commandPostProcess));
my $postAlignStopTime = time();
my $postAlignTime = &ceil(($postAlignStopTime-$postAlignStartTime)/60);
print "Alignment post-processing time: $postAlignTime minutes\n";

# flowspace realignment, if requested
#if($opt->{"realign"}) {
#  my $command = "tmap sam2fs -S $samFile -l 2 -O 1 > ".$opt->{"out-base-name"}.".flowspace.sam";
#  die "$0: failure during flowspace realignment\n" if(&executeSystemCall($command));
#}

# Cleanup files
unlink($truncatedFile) if(defined($opt->{"trim-length"}) && (-e $truncatedFile));
my @qScores = split(",",$opt->{"qscores"});
foreach my $qScore (@qScores) {
  my $covFile = $opt->{"out-base-name"}.".$qScore.coverage";
  unlink($covFile) if(-e $covFile);
}

exit(0);




sub executeSystemCall {
  my ($command,$returnVal) = @_;

  # Initialize status tracking
  my $exeFail  = 0;
  my $died     = 0;
  my $core     = 0;
  my $exitCode = 0;

  # Run command
  if(!defined($returnVal)) {
    system($command);
  } else {
    $$returnVal = `$command`;
  }

  # Check status
  if ($? == -1) {
    $exeFail = 1;
  } elsif ($? & 127) {
   $died = ($? & 127);
   $core = 1 if($? & 128);
  } else {
    $exitCode = $? >> 8;
  }

  my $problem = 0;
  if($exeFail || $died || $exitCode) {
    print STDERR "$0: problem encountered running command \"$command\"\n";
    if($exeFail) {
      print STDERR "Failed to execute command: $!\n";
    } elsif ($died) {
      print STDERR sprintf("Child died with signal %d, %s coredump\n", $died,  $core ? 'with' : 'without');
    } else {
      print STDERR "Child exited with value $exitCode\n";
    }
    $problem = 1;
  }

  return($problem);
}

sub checkArgs {
  my($opt) =@_;

  if($opt->{"help"}) {
    &usage();
    exit(0);
  }
  
  print "  printing alignmentQC.pl options:\n";
  for my $key (keys %$opt) {
    if(!defined($opt->{$key})) {
      print "    $key:\"undef\"\n";
    }
    else {
      print "    $key: \"" . $opt->{$key} . "\"\n";
    }
  }
  
  # Check args for things that are not allowed
  my $badArgs = 0;
  if($opt->{"threads"} < 1) {
    $badArgs = 1;
    print STDERR "ERROR: $0: must specify a positive number of threads\n";
  }
  if(!defined($opt->{"readFile"})) {
    $badArgs = 1;
    print STDERR "ERROR: $0: must specify input reads with -i or --input option\n";
  } elsif($opt->{"readFile"} =~ /^(.+)\.(fasta|fastq|sff)$/i) {
    $opt->{"readFileBase"} = $1;
    $opt->{"readFileType"} = lc($2);
  } else {
    $badArgs = 1;
    print STDERR "ERROR: $0: suffix of input reads filename must be one of (.fasta, .fastq, .sff)\n";
  }
  if(!defined($opt->{"genome"})) {
    $badArgs = 1;
    print STDERR "ERROR: $0: must specify reference genome with -g or --genome option\n";
  }
  if($badArgs) {
    &usage();
    exit(1);
  }

  # Check args for things that might be problems
  if($opt->{"threads"} > &numCores()) {
    print STDERR "WARNING: $0: number of threads is larger than number available, limiting.\n";
    $opt->{"threads"} = &numCores();
  }
}

sub usage () {
  print STDERR << "EOF";

usage: $0
  Required args:
    -i,--input myReads         : Single file to align (fasta/fastq/sff)
    -g,--genome mygenome       : Genome to which to align
  Optional args:
    -o,--out-base-name          : Base name for output files.  Default is to
                                  use same base name as input file
    -l,--filter-length len      : alignments based on reads this short or
                                  shorter will be ignored when compiling
                                  alignment summary statistics.  If not
                                  specified will be taken from
                                  genome.info.txt, otherwise will be set to 20bp
    -t,--trim-length len        : Length to which to truncate reads.  By default
                                  no trimming is applied.
    -s,--start-slop nBases      : Number of bases at 5' end of read that can be
                                  ignored when scoring alignments
    -n,--sample-size nReads     : Number of reads to sample.  If not specified
                                  will be taken from genome.info.txt
    -m,--max-plot-read-len len  : Maximum read length for read length histograms
                                  Default is 200bp
    -q,--qscores 10,20,30       : Comma-separated list of q-scores at which to
                                  evaluate lengths.  Default is 7,10,17,20,47
    -b,--threads nThreads       : Number of threads to use - default is the
                                  number of physical cores
    -d,--aligner tmap           : The aligner to use - currently only tmap
    --aligner-opts-rg options   : SAM Read Group options aligner-specific options
                                  (ex. "-R" for TMAP)
    --aligner-opts-extra options : Additional extra options to pass to aligner 
                                  (if this is not specified, "stage1 map1 map2 map3" 
                                  will be used).
    -c,--align-all-reads        : Over-ride possible sampling, align all reads
    -a,--genome-path /dir       : Path in which references can be found.  Can
                                  be specified multiple times.  By default
                                  /opt/ion/referenceLibrary then
                                  /results/referenceLibrary are searched.
    -p,--sam-parsed             : Generate .sam.parsed file (not a standard
                                  format - do not rely on it)
    -r,--realign                : Create a flowalign.sam with flow-space
                                  realignment (experimental)
    --output-dir                : Output directory for stats output
    -h,--help                   : This help message
EOF
}

sub numCores {

  my $commandCore = "cat /proc/cpuinfo | grep \"core id\" | sort -u | wc -l";
  my $nCore = 0;
  die "$0: Failed to determine number of cores\n" if(&executeSystemCall($commandCore,\$nCore));
  chomp $nCore;

  my $commandProc = "cat /proc/cpuinfo | grep \"physical id\" | sort -u | wc -l";
  my $nProc = 0;
  die "$0: Failed to determine number of processors\n" if(&executeSystemCall($commandProc,\$nProc));
  chomp $nProc;

  my $nTotal = $nCore * $nProc;
  $nTotal = 1 if($nTotal < 1);

  return($nTotal);
}


sub findReference {
  my($genomePath,$genome,$aligner,$indexVersion) = @_;

  die "ERROR: $0: no base paths defined to search for reference library\n" if(@$genomePath == 0);

  my $dirName = "$indexVersion/$genome";
  my $found = 0;
  my $refLocation = undef;
  foreach my $baseDir (reverse @$genomePath) {
    $refLocation = "$baseDir/$dirName";
    if(-e $refLocation) {
      $found = 1;
      last;
    }
  }

  if(!$found) {
    print STDERR "ERROR: $0: unable to find reference genome $dirName\n";
    print STDERR "Searched in the following locations:\n";
    print STDERR join("\n",map {"$_/$dirName"} reverse(@$genomePath))."\n";
    die;
  }

  my $fastaFile = "$refLocation/$genome.fasta";
  die "ERROR: $0: unable to find reference fasta file $fastaFile\n" if(! -e $fastaFile);

  my $infoFile = "$refLocation/$genome.info.txt";
  open(INFO,$infoFile) || die "$0: unable to open reference genome info file $infoFile: $!\n";
  my $info = {};
  my $lineCount = 0;
  while(<INFO>) {
    $lineCount++;
    next if(/^\s*#/ || /^\s*$/);
    chomp;
    my @F = split "\t";
    die "$0: bad format in line $lineCount of genome info file $infoFile\n" if(@F != 2);
    $info->{$F[0]} = $F[1];
  }
  close(INFO);


  return($refLocation,$info,$fastaFile,$infoFile);
}

sub getReadNumber {
  my($readFile,$fileType) = @_;

  my $nReads=0;
  if($fileType eq "fastq") {
    my $command = "cat $readFile | wc -l";
    die "$0: Failed to determine number of reads from $readFile\n" if(&executeSystemCall($command,\$nReads));
    chomp $nReads;
    $nReads =~ s/\s+//g;
    $nReads /= 4;
  } elsif($fileType eq "fasta") {
    my $command = "grep -c \"^>\" $readFile";
    die "$0: Failed to determine number of reads from $readFile\n" if(&executeSystemCall($command,\$nReads));
    chomp $nReads;
    $nReads =~ s/\s+//g;
  } elsif($fileType eq "sff") {
    my $command = "SFFSummary -q 0 -m 0 -s $readFile | grep \"^reads\" | cut -f2- -d\\ ";
    die "$0: Failed to determine number of reads from $readFile\n" if(&executeSystemCall($command,\$nReads));
    chomp $nReads;
    $nReads =~ s/\s+//g;
  } else {
    die "$0: don't know how to determine number of reads for file type $fileType\n";
  }

  return($nReads);
}

sub extendSuffix {
  my($file,$suffix,$extension) = @_;

  my $newFile = "$file.$extension";
  if($file =~ /^(.+)\.($suffix)$/i) {
    $newFile = "$1.$extension.$2";
  }

  return($newFile);
}

sub getIndexVersion {

  my $command = "tmap index --version";
  my $indexVersion = undef;
  die "$0: Problem encountered determining tmap format version\n" if(&executeSystemCall($command,\$indexVersion));
  chomp $indexVersion if(defined($indexVersion));

  return($indexVersion);
}
