#!/sw/bin/perl

# The MIT License (MIT)
# Copyright (c) Michael Hiller, 2014

# Version 1.0

# implements parasol functionality for LSF
# it uses files in a local directory .para/ to keep track of the jobs in a jobList and their status
# 06/2013: New feature. If a job failed because the runtime limit of the queue was reached, it will be re-submitted to the next longest queue (unless -noResubmitIfQueueMaxTimeExceeded is given). 


use strict;
use warnings;

use Getopt::Long qw(:config no_ignore_case no_auto_abbrev);
use Scalar::Util::Numeric qw(isint);
use Date::Manip;
use List::MoreUtils qw( natatime );

######################################
# PARAMETERS YOU MUST CONFIGURE
my $clusterHeadNode = "madmax";		# specify here the hostname of the cluster head node (the computer that is able to submit jobs to LSF). The script will only run when executed on this node. 
my $queue = "short";						# short queue is the default
my $maxRunTimeQueue = "long";			# the queue with the maximum runtime
# used if jobs reach the run time limit of a queue and have to be resubmitted (used in pushCrashed)
my %Queue2Order;
$Queue2Order{"short"} = 0;
$Queue2Order{"medium"} = 1;
$Queue2Order{"long"} = 2;
my %Order2Queue;
$Order2Queue{0} = "short";
$Order2Queue{1} = "medium";
$Order2Queue{2} = "long";
######################################

######################################
# optional configurable default parameters
my $maxNumResubmission = 3;			# max number of times a job gets resubmitted, in case it crashed
my $numAtATime = 1000;					# call bjobs with that many jobIDs max
my $maxNumOutFilesPerDir = 1000;		# we generate LSF output files for each job in the .para/$jobListName/$subDir dir. 
												# This value determines how many files will be generated per $subDir to avoid overloading lustre with too many files in a single dir. 
my $maxNumFastSleepCycles = 10;		# do that many cycles where we sleep only $sleepTime1, after that sleep $sleepTime2
my $sleepTime1 = 45;						# time in seconds
my $sleepTime2 = 90;
my $sleepTimeLSFBusy = 180;			# time to wait if LSF is too busy
#####################################

#####################################
# other parameters
$| = 1;										# == fflush(stdout)
my $verbose = 0;							# flag
my $noResubmitIfQueueMaxTimeExceeded = 0;           # if set to 1, do not resubmit the jobs that failed because they exceeded the runtime limit of the queue
my $resubmitToSameQueueIfQueueMaxTimeExceeded = 0;  # if set to 1, resubmit the jobs that failed because they exceeded the runtime limit of the queue, but resubmit to the same (rather than the next longest) queue. 
                                                    # Only useful, if your job checks which preliminary results exist (e.g. for input elements the output file already exist)
my $keepBackupFiles = 0;            # if set, keep a backup of every internal para file in a dir .para/backup/
my $totalNoJobsPushed = -1;			# in case of push or make, keep track of how many jobs were pushed
my $bsubParameters = "";				# default parameters for bsub
#####################################

# usage
my $usage = "$0 action jobListName [jobListFile] [-q queue] [-p bsubParameters] [-v|verbose] [-maxNumResubmission int] [-noResubmitIfQueueMaxTimeExceeded] [-resubmitToSameQueueIfQueueMaxTimeExceeded] [-keepBackupFiles]
where action can be:    make, push, pushCrashed, check, wait, stop, chill, time, crashed, clean\n
\tmake          pushes the joblist, monitors progress, pushes failed jobs again a maximum of $maxNumResubmission times, waits until all jobs are done or jobs crashed >$maxNumResubmission times
\tpush          pushes the joblist
\tpushCrashed   determines which jobs crashed and pushes those jobs again unless they failed $maxNumResubmission times already. It uses the same bsub parameters. Queue is the same, unless a job failed with exceeding the runtime limit.
\tcheck         checks how many jobs in the current joblist are done. Exit code 0 if all succeeded. Otherwise exit code 255. 
\twait          'connects' to a running jobList and waits until the running and pending jobs are done, pushes failed jobs again a max of $maxNumResubmission times.
\tstop          stops all running and pending jobs in the jobList --> You can recover all stopped and crashed jobs with 'crashed'
\tchill         stops all pending jobs only. Lets the running jobs continue to run. --> You can recover all stopped and crashed jobs with 'crashed'
\ttime          outputs runtime statistics and an estimation when all jobs are finished
\tcrashed       outputs all crashed jobs into the given output filename
\tclean         remove all internal para files and LSF output files for the given jobListName
The number of input parameters depends on the action:
\t$0 make          jobListName  jobListFile  [-q|queue short|medium|long] [-p|parameters \"additional parameters for bsub\"] [-maxNumResubmission int] [-noResubmitIfQueueMaxTimeExceeded] [-resubmitToSameQueueIfQueueMaxTimeExceeded]
\t$0 push          jobListName  jobListFile  [-q|queue short|medium|long] [-p|parameters \"additional parameters for bsub\"] [-maxNumResubmission int] [-noResubmitIfQueueMaxTimeExceeded] [-resubmitToSameQueueIfQueueMaxTimeExceeded]
\t$0 pushCrashed   jobListName  
\t$0 check         jobListName
\t$0 wait          jobListName
\t$0 stop          jobListName
\t$0 chill         jobListName
\t$0 time          jobListName
\t$0 crashed       jobListName  outputJobListFile
\t$0 clean         jobListName\n
General parameters
\t-v|--verbose                                 enable verbose output
\t-maxNumResubmission int                      set the max number of times a crashed job will be pushed again (default $maxNumResubmission). NOTE: has only an effect when doing para make
\t-noResubmitIfQueueMaxTimeExceeded            do not resubmit the jobs that failed because they exceeded the runtime limit of the queue (default is do resubmit)
\t-resubmitToSameQueueIfQueueMaxTimeExceeded   resubmit the jobs that failed because they exceeded the runtime limit of the queue, but resubmit to the same (rather than the next longest) queue. 
\t                                             Only useful, if your job checks which preliminary results exist (e.g. for input elements the output file already exist).
\t-keepBackupFiles                             if set, keep a backup of every internal para file in a dir .para/backup/ (backup files will be produced everytime the internal files are updated)
";

# first thing: check if the script is executed on $clusterHeadNode
my $hostname = $ENV{'HOSTNAME'};
die "######### ERROR #########: You have to execute $0 on $clusterHeadNode! Not on $hostname.\n" if ($hostname ne $clusterHeadNode);

# parse options
GetOptions ("v|verbose"  => \$verbose, "p|parameters=s" => \$bsubParameters, "q|queue=s" => \$queue, "maxNumResubmission=i" => \$maxNumResubmission, 
            "noResubmitIfQueueMaxTimeExceeded" => \$noResubmitIfQueueMaxTimeExceeded, "resubmitToSameQueueIfQueueMaxTimeExceeded" => \$resubmitToSameQueueIfQueueMaxTimeExceeded, 
            "keepBackupFiles" => \$keepBackupFiles) 
		|| die "$usage\n";
die "ERROR: Set only one of -resubmitToSameQueueIfQueueMaxTimeExceeded and -noResubmitIfQueueMaxTimeExceeded but not both !" if ($resubmitToSameQueueIfQueueMaxTimeExceeded == 1 && $noResubmitIfQueueMaxTimeExceeded == 1);
die "Parameters missing!!\n\n$usage\n" if ($#ARGV < 1);

# global parameters. Needed for every command. 
my $jobListName = $ARGV[1];
# internal .para file names keeping track of the jobs and their status
my $paraJobsFile = "./.para/.para.jobs.$jobListName";
my $paraStatusFile = "./.para/.para.status.$jobListName";
my $paraBsubParaFile = "./.para/.para.bsubParameters.$jobListName";
my $paraJobNoFile = "./.para/.para.jobNo.$jobListName";
my $paraJobsFilebackup = "./.para/backup/.para.jobs.$jobListName.backup";
my $paraStatusFilebackup = "./.para/backup/.para.status.$jobListName.backup";
my $paraBsubParaFilebackup = "./.para/backup/.para.bsubParameters.$jobListName.backup";

# we need the user name for bjobs below
my $user = $ENV{'USER'};
print "USER: $user\n" if ($verbose);

# test if the given action is correct
my $action = $ARGV[0];
die "$usage\n" if (! ($action eq "make" || $action eq "wait" || $action eq "push" || $action eq "pushCrashed" || $action eq "check" || $action eq "time" || $action eq "stop" || $action eq "chill" || $action eq "crashed" || $action eq "clean") );
# if push or make: test if the queue is correct and if jobList exist
if ($action eq "make" || $action eq "push") {
	die "######### ERROR #########: parameter -q|queue must be set to short, medium, long. Not to $queue.\n" if (! ($queue eq "short" || $queue eq "medium" || $queue eq "long"));
	# test if jobListname and jobList file are given
	die "Parameters missing!!\n\n$usage\n" if ($#ARGV < 2);
	# test if jobList exist
	die "######### ERROR #########: jobListFile $ARGV[2] does not exist\n" if (! -e $ARGV[2]);
# otherwise check if the internal .para files exist and check if these files have an entry for every submitted job
}else{
	# test if the internal job and jobStatus files exist in the current directory
	checkIfInternalFilesExist($jobListName);
}

# based on the action, decide what to do and test if the number of parameters is correct
if ($action eq "make") {
	# now push and then wait until finished
	pushJobs();
	waitForJobs();

} elsif ($action eq "push") {
	# now push 
	pushJobs();

} elsif ($action eq "pushCrashed") {
	# For pushing failed jobs again, we need the bsub parameter file.
	die "######### ERROR #########: internal file $paraBsubParaFile not found in this directory\n" if (! -e "$paraBsubParaFile");

	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
	printf "numJobs: %-7d\tRUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d  (%d of them failed $maxNumResubmission times)\tallDone: %s\n", $numJobs,$numRun,$numPend,$numDone,$numFailed,$numFailed-$allnumFailedLessThanMaxNumResubmission,($allDone == 1 ? "YES" : "NO");	
	# push crashed jobs again, if some failed less than $maxNumResubmission times
	if ($allnumFailedLessThanMaxNumResubmission > 0) {
		pushCrashed($jobIDsFailedLessThanMaxNumResubmission);
	}else{
		if ($numFailed > 0 && $allnumFailedLessThanMaxNumResubmission == 0)	{
			print "All $numFailed crashed jobs crashed $maxNumResubmission times already --> No job is repushed !!  Run '$0 crashed' to list those crashed jobs, fix them and submit a new jobList.\n";
		}elsif ($numFailed == 0) {
			print "There are NO crashed jobs. \n";
		}
	}

} elsif ($action eq "wait") {
	# wait involved potentially pushing failed jobs again. Therefore we need the bsub parameter file.
	die "######### ERROR #########: internal file $paraBsubParaFile not found in this directory\n" if (! -e "$paraBsubParaFile");
	waitForJobs();

} elsif ($action eq "check") {
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
	printf "RUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d (%d of them failed $maxNumResubmission times)\n", $numRun,$numPend,$numDone,$numFailed,$numFailed-$allnumFailedLessThanMaxNumResubmission;
	if ($allDone == 1) {
		print "*** ALL JOBS SUCCEEDED ***\n";
		exit 0;
	}elsif ($allDone == -1) {
		print "*** CRASHED: Some jobs failed $maxNumResubmission times !!  Run '$0 crashed' to list those crashed jobs. ***\n";
	}	
	if ($allnumFailedLessThanMaxNumResubmission > 0) {
		print "*** Some jobs crashed. Run '$0 pushCrashed' to push the crashed jobs again. Run '$0 crashed' to list those crashed jobs. ***\n";
	}
	
	# para check can be used to test if the entire jobList succeeded (exit 0). Otherwise if jobs are still running or failed, exit -1.
	exit -1;

} elsif ($action eq "time") {
	gettime();

} elsif ($action eq "stop") {
	killJobs("stop");

} elsif ($action eq "chill") {
	killJobs("chill");

} elsif ($action eq "crashed") {
	# test if output filename is given as the third parameter
	die "Parameters missing!!\n\n$usage\n" if ($#ARGV < 2);	
	crashed();

} elsif ($action eq "clean") {
	clean();

=pod
} elsif ($action eq "restore") {
	restore();
=cut
}


#####################################################
# die if the $paraJobsFile and $paraStatusFile file for the given jobListName don't exist
#####################################################
sub checkIfInternalFilesExist {
	die "######### ERROR #########: internal file $paraJobsFile not found in this directory\n" if (! -e "$paraJobsFile");
	die "######### ERROR #########: internal file $paraStatusFile not found in this directory\n" if (! -e "$paraStatusFile");
	
	# compare if the line count in $paraJobsFile and $paraStatusFile equals $noOfSubmittedJobs --> otherwise these files are corrupted
	my $lineNoparaJobsFile = `cat $paraJobsFile | wc -l`; chomp($lineNoparaJobsFile);
	my $lineNoparaStatusFile = `cat $paraStatusFile | wc -l`; chomp($lineNoparaStatusFile);
	my $noOfSubmittedJobs = `cat $paraJobNoFile`; chomp($noOfSubmittedJobs);
	
	print "checkIfInternalFilesExist(): number of lines in $paraJobsFile = $lineNoparaJobsFile. $paraStatusFile = $lineNoparaStatusFile. Number of submitted jobs $noOfSubmittedJobs\n" if ($verbose);
	
	if ($noOfSubmittedJobs != $lineNoparaJobsFile) {
		die "ERROR: the number of lines in $paraJobsFile ($lineNoparaJobsFile) does not equal the number of submitted jobs $noOfSubmittedJobs --> internal para files are corrupted\n";
	}
	if ($noOfSubmittedJobs != $lineNoparaStatusFile) {
		die "ERROR: the number of lines in $paraStatusFile ($lineNoparaStatusFile) does not equal the number of submitted jobs $noOfSubmittedJobs --> internal para files are corrupted\n";
	}
}

#####################################################
# push a single job given the parameters and the job, return jobID 
#####################################################
sub pushSingleJob {
	my ($parameters, $job) = @_;

	# check if the job has special characters
	# if so, don't submit the job directly but wrap it in a sh -c
	# Here is the rationale
	#	bsub -q short -e ./e -o ./o sh -c 'egrep "^s hg18" input.maf | awk '\'\\\'\''{print length($7)}'\'\\\'\'' > input.maf.out'
	#	This submits 
	#	sh -c 'egrep "^s hg18" input.maf | awk '\''{print length($7)}'\'' > intput.maf.out'
	#	A 
	#	'\''
	#	gives a single
	#	' 
	#	after interpretation by the shell (you end the sh -c '   then output a ' by \'   and then re-start the sh -c string with another '). 
	#	Because the shell interprets the command twice (once when we call bsub, a second time when sh -c '..' is executed), we have to provide the full escape code to produce a ' after the second round of interpretation.
	#	Thus a single ' becomes '\'\\\'\''
	#	
	if ($job =~ /[!$^&*(){}"'?]/) {
		print "\t\t job with special chars: $job\n" if ($verbose);
		# NOTE: We have to mask every backslash in addition here. This replace does ' --> '\'\\\'\''
		$job =~ s/'/'\\'\\\\\\'\\''/g;
		print "\t\t\tgets masked: $job\n" if ($verbose);
		my $job_sh = "sh -c '$job'";
		print "\t\t\tand submitted as : $job_sh\n" if ($verbose);
		$job = $job_sh;
	}else{
		$job = "\"$job\"";
	}

	my $command = "bsub -J $jobListName $parameters $job";
	print "\t$command\n" if ($verbose);
	my $result = `$command`;
	die "######### ERROR ######### in pushSingleJob: $command failed with exit code $?\n" if ($? != 0);

	# get the LSF job ID
	my $ID = (split(/[<>]/, $result))[1];
	print STDERR "######### ERROR #########: $command results in an ID that is not a number: $ID\n" if (! isint($ID));
	return $ID;
}


#####################################################
# get the lockfile (atomic operation)
#####################################################
sub getLock {
	print "Waiting to get ./lockFile.$jobListName   ..... [Takes too long? Did a previous para run died? If so, open a new terminal and   rm -f ./lockFile.$jobListName ] .....  ";
	system "lockfile -1 ./lockFile.$jobListName" || die "######### ERROR #########: cannot get lock file: ./lockFile.$jobListName\n";
	print "got it\n";
}

#####################################################
# push the entire joblist, create the internal .para files to keep track of all pushed jobs
#####################################################
sub pushJobs {

	my $jobListFile = $ARGV[2];
   
	# create the .para dir, in case it does not exist
	if (! -d "./.para") {
		system("mkdir ./.para") == 0 || die "######### ERROR #########: cannot create the ./.para directory\n";	
	}
	if (($keepBackupFiles == 1) && (! -d "./.para/backup")) {
		system("mkdir ./.para/backup") == 0 || die "######### ERROR #########: cannot create the ./.para/backup directory\n";	
	}

	# make sure we never clobber the $paraJobsFile and $paraStatusFile files if they already (or still) exist. 
	# We avoid clobbering the files if a user accidentally pushes the jobList or another list using the same jobListName
   if (-e  "$paraJobsFile" || -e "$paraStatusFile" || -e "$paraBsubParaFile" || -e "$paraJobNoFile" || -d "./.para/$jobListName") {
		die "######### ERROR #########: Looks like a jobList with the name $jobListName already exists (files ./.para/.para.[jobs|status|bsubParameters|jobNo].$jobListName and/or .para/$jobListName exist).
If this is not an accident, do \n\tpara clean $jobListName\nand call again\n" 
	}

	print "**** PUSH Jobs to queue: $queue\n";
	print "**** Additional bsub parameters: $bsubParameters\n" if ($bsubParameters ne "");

	# write the bsub parameters to $paraBsubParaFile    We need these parameters in case jobs fail and have to be pushed again.
	# Note that the queue depends on the job as jobs that exceed the max runtime of the specified queue will be pushed to 'long'. 
	# The queue is therefore not added to the bsubParameter file. 
	getLock();
	open (filePara, ">$paraBsubParaFile") || die "######### ERROR #########: cannot create $paraBsubParaFile\n";
	print filePara "$bsubParameters\n";
	close filePara;

	# create the two internal para files listing the jobs and their status
	open (fileJobs, ">$paraJobsFile") || die "######### ERROR #########: cannot create $paraJobsFile\n";
	open (fileStatus, ">$paraStatusFile") || die "######### ERROR #########: cannot create $paraStatusFile\n";
	print "pushJobs: push the following jobs .... \n" if ($verbose);
	
	# read all the jobs and push
	open(file1, $jobListFile) || die "######### ERROR #########: cannot open $jobListFile\n";
	my $line;
	my $numJobs = 0;
	my $subDir = 0;
	system("mkdir -p ./.para/$jobListName/")  == 0 || die "######### ERROR #########: cannot create the ./.para/$jobListName directory\n";	
	while ($line = <file1>) {
		chomp($line);

		# start a new subdir if $maxNumOutFilesPerDir files in the current $subdir are reached
		if ($numJobs % $maxNumOutFilesPerDir == 0) {
			$subDir ++;
			system("mkdir -p ./.para/$jobListName/$subDir")  == 0 || die "######### ERROR #########: cannot create the ./.para/$jobListName/$subDir directory\n";	
		}

		# push the job and get the jobID back
		# the jobName is $jobListName/$subDir/o.$numJobs which is the output file in the .para dir
		my $jobName = "$jobListName/$subDir/o.$numJobs";
		my $ID = pushSingleJob("-q $queue $bsubParameters -o ./.para/$jobName", $line);

		# write job, its (current) queue and its ID and name to $paraJobsFile
		print fileJobs "$ID\t$jobName\t$queue\t$line\n";
		# write the jobID, jobName and PEND to $paraStatusFile
		print fileStatus "$ID\t$jobName\tPEND\t0\t-1\n";

		$numJobs ++;
	}
	close file1;
	close fileJobs;
	close fileStatus;
	
	# make a backup copy with version number 0 that refers to these original files
	firstBackup();

	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	
	print "DONE.\n$numJobs jobs pushed using parameters: -q $queue $bsubParameters\n\n";
	
	# keep track of how many jobs we have pushed --> write to a file
	open (fileJobNo, ">$paraJobNoFile") || die "######### ERROR #########: cannot create $paraJobNoFile\n";
	print fileJobNo "$numJobs\n";
	close fileJobNo;
	
	# in case of para make, store job number in a global variable
	$totalNoJobsPushed = $numJobs;
}


#####################################################
# check the status of all jobs
# New functionality: Only run bjobs for jobs that are not DONE. When a job finishes (EXIT/RUN/PEND --> DONE), run getRunTime to get store the runtime for that job.
# REASON: LSF command bjobs is only able to lookup a certain number of finished jobs. If that job finished a while ago, bjobs cannot find it anymore. In that case, we use the output file.  
#####################################################
sub check {
	  
	getLock();

	# for overall stats
	my $allnumRun = 0;
	my $allnumPend = 0;
	my $allnumFailed = 0;
	my $allnumDone = 0;
	
	# we need to keep track of the jobName for a given jobID because we have to look into .para/$jobName file to get the jobs status in case bjobs does not find the job anymore
	my %jobID2jobName;

	# get all IDs for jobs that are not DONE from $paraStatusFile file
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my @oldStatus = <fileStatus>;
	chomp(@oldStatus);
	close fileStatus;
	# sort by ID
	my @oldStatusSort = sort( {
		my $ID1 = (split(/\t/, $a))[0];
		my $ID2 = (split(/\t/, $b))[0];
		return $ID1 <=> $ID2;
	}  @oldStatus); 
	@oldStatus = @oldStatusSort;
	if ($verbose) {
		$" = "\n\t"; print "CHECK: old Status array:\n\t@oldStatus\n";
	}
	my @IDs;	
	my $newStatus_ = "";	 # status of all jobs: Those that are DONE and the update for EXIT/PEND/RUN jobs as returned from runbjobs()
	for (my $i=0; $i<=$#oldStatus; $i++) {
		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $oldStatus[$i]))[0,1,2,3,4];
		if ($status ne "DONE") {
			# check this job with bjobs later --> add to IDs
			push @IDs, $jobID;
		}else{
			# jobs was marked as DONE from the last call of check() --> just increase the counter and add to $newStatus_ as the status of this job will not change anymore (also its runtime, which we have determined already)
			$allnumDone ++;
			$newStatus_ .= "$oldStatus[$i]\n";
		}
		$jobID2jobName{$jobID} = $jobName;
	}
	print "\n\nCHECK: IDs @IDs\n" if ($verbose);

	# lets run bjobs jobID1 jobID2 ... to check the status of all jobs
	# we can easily give 1000 job IDs at once, use the natatime function for that (List::MoreUtils)
	$" = " ";	   # space as separator for the array
	my $it = natatime $numAtATime, @IDs;
	while (my @vals = $it->())  {
		# run bjobs, we don't make use of numRun etc here
		my ($status, $numRun, $numPend, $numFailed, $numDone) = runbjobs("@vals", \%jobID2jobName); 
		$allnumRun += $numRun;
		$allnumPend += $numPend;
		$allnumFailed += $numFailed;
		$allnumDone += $numDone;	
		$newStatus_ .= $status;
	}
	# sort by ID
	my @newStatus = sort( {
		my $ID1 = (split(/\t/, $a))[0];
		my $ID2 = (split(/\t/, $b))[0];
		return $ID1 <=> $ID2;
	}  split(/\n/, $newStatus_)  );	 # split the string $newStatus_ to get an array to sort
	if ($verbose) {
		$" = "\n\t"; print "CHECK: new Status array:\n\t@newStatus\n";
	}
	
	# count how many jobs could be repushed and collect their jobIDs (is used for pushCrashed())
	my $allnumFailedLessThanMaxNumResubmission = 0;		
	my @jobIDsFailedLessThanMaxNumResubmission;
	
	# now clobber the $paraStatusFile file and update the status of each job
	# @newStatus is the new status of each job after running bjobs. @oldStatus is the content of $paraStatusFile
	backup();
	open (fileStatus, ">$paraStatusFile") || die "######### ERROR #########: cannot create $paraStatusFile\n";
	for (my $i=0; $i<=$#newStatus; $i++) {

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID1, $jobName1, $status1, $howOftenFailed1, $runTime1) = (split(/\t/, $oldStatus[$i]))[0,1,2,3,4];
		my ($jobID2, $jobName2, $status2, $howOftenFailed2, $runTime2) = (split(/\t/, $newStatus[$i]))[0,1,2,3,4];
#		print "\tCHECK: compare\n\t$oldStatus[$i]\n\t$newStatus[$i]\n" if ($verbose);
		
		# Important: We will compare old and new status. Works only if the two arrays are sorted. Check ! 
		print STDERR "######### ERROR ######### in check: jobID1 != jobID2  ($jobID1 != $jobID2)\n" if ($jobID1 != $jobID2);

		# now update
		# a job failed
		if (($status1 eq "PEND" || $status1 eq "RUN") && ($status2 eq "EXIT") ) {
			print "\tCHECK: $jobID1 crashed ($status1 --> $status2)   num times crashed before $howOftenFailed1\n" if ($verbose);
			$howOftenFailed1 ++;
			if ($howOftenFailed1 < $maxNumResubmission) {
				# push the job if noResubmitIfQueueMaxTimeExceeded is not set OR if the job did not exceed the runtime limit
				if ($noResubmitIfQueueMaxTimeExceeded == 0 || doesCrashedJobReachedRuntimeLimit($jobID1, $jobName1) == 0) {
					push @jobIDsFailedLessThanMaxNumResubmission, $jobID1;
					$allnumFailedLessThanMaxNumResubmission ++;	
				}else{
					print "\t--> Do not push this job again because it crashed by exceeding the queue runtime and noResubmitIfQueueMaxTimeExceeded is set! (set #crashes to $maxNumResubmission)\n" if ($verbose);
					$howOftenFailed1 = $maxNumResubmission;	
				}
			}
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";   # time does not matter here

		# a job went from pend to run
		}elsif ( ($status1 eq "PEND") && ($status2 eq "RUN") ) {
			print "\tCHECK: $jobID1 is now running ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";
			
		# a job is still running
		}elsif ( ($status1 eq "RUN") && ($status2 eq "RUN") ) {
			print "\tCHECK: $jobID1 is still running ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";

		# a job is still pending
		}elsif ( ($status1 eq "PEND") && ($status2 eq "PEND") ) {
			print "\tCHECK: $jobID1 is still pending ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status1\t$howOftenFailed1\t-1\n";
			
		# a job is now done (was RUN or PEND before). In case of EXIT the job must have been repushed and pushCrashed would have updated the status to PEND
		}elsif ( ($status1 ne "DONE") && ($status2 eq "DONE") ) {
			print "\tCHECK: $jobID1 succeeded since checking last time ($status1 --> $status2)\n" if ($verbose);
			# if the status of the job was determined not by bjobs but by looking into its output file, we have the runtime already. 
			# otherwise, we try to get the runtime here. As the job likely finished not so long time ago, bjobs -l should still find the job (faster solution). 
			#   If bjobs does not find the job, the getRunTime fct calls bhist instead.
			my $runTime = -1;
			if ($runTime2 > 0) {			# NOTE: if a job took only 0 seconds, getRunTime returns 1 second
				$runTime = $runTime2;
			}else{
				$runTime = getRunTime($jobID1, -1);		# NOTE: This job finished, therefore we don't need to pass the current time. 
			}
			# write the proper runTime to the file. Then we never have to get the runtime for that job again. 
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t$runTime\n";

		# a job is was done before
		}elsif ( ($status1 eq "DONE") && ($status2 eq "DONE") ) {
			print "\tCHECK: $jobID1 succeeded before ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$oldStatus[$i]\n";							# this run time will never change anymore. 

		# a failed job is now pending 
		}elsif ( ($status1 eq "EXIT") && ($status2 eq "PEND") ) {
			print "\tCHECK: $jobID1 failed before $howOftenFailed1 times and is now pending again ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";
			
		# a failed job is now running
		}elsif ( ($status1 eq "EXIT") && ($status2 eq "RUN") ) {
			print "\tCHECK: $jobID1 failed before $howOftenFailed1 times and is now running again ($status1 --> $status2)\n" if ($verbose);
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";

		# a failed job is still failed (was not pushed again. In case of being pushed again, we set the status to PEND)
		}elsif ( ($status1 eq "EXIT") && ($status2 eq "EXIT") ) {
			print "\tCHECK: $jobID1 failed before $howOftenFailed1 times and was not repushed ($status1 --> $status2)\n" if ($verbose);
			if ($howOftenFailed1 < $maxNumResubmission) {
				# push the job if noResubmitIfQueueMaxTimeExceeded is not set OR if the job did not exceed the runtime limit
				if ($noResubmitIfQueueMaxTimeExceeded == 0 || doesCrashedJobReachedRuntimeLimit($jobID2, $jobName2) == 0) {
					push @jobIDsFailedLessThanMaxNumResubmission, $jobID1;
					$allnumFailedLessThanMaxNumResubmission ++;	
				}else{
					print "\t--> Do not push this job again because it crashed by exceeding the queue runtime and noResubmitIfQueueMaxTimeExceeded is set! (set #crashes to $maxNumResubmission)\n" if ($verbose);
					$howOftenFailed1 = $maxNumResubmission;	
				}
			}
			print fileStatus "$jobID1\t$jobName1\t$status2\t$howOftenFailed1\t-1\n";

		# ERROR
		}else{
			die "######### ERROR ######### in check: $oldStatus[$i] --> $newStatus[$i] is a case that is not covered\n";
		}
	}
	close fileStatus;
	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	
	
	my $numJobs = $allnumRun + $allnumPend + $allnumFailed + $allnumDone;

	# sanity check. If you run para make, we know how many jobs we have pushed. Compare. 
	print STDERR "######### ERROR #########: totalNoJobsPushed != numJobs ($totalNoJobsPushed != $numJobs) in check()\n" if ($totalNoJobsPushed != -1 && $totalNoJobsPushed != $numJobs);

	# flag if everything succeeded or some failed repeatedly
	# 0 means not finished, 
	# 1 all completed successfully
	# -1 no jobs are running and all either succeeded or failed repeatedly (no job could be repushed due to failing $maxNumResubmission times already)
	# -2 all jobs either succeeded or failed but failed jobs could be repushed
	my $allDone = 0;
	$allDone = 1  if ($allnumDone == $numJobs);
	$allDone = -1 if ($allnumDone + $allnumFailed == $numJobs && $allnumFailed > 0 && $allnumFailedLessThanMaxNumResubmission == 0);
	$allDone = -2 if ($allnumDone + $allnumFailed == $numJobs && $allnumFailed > 0 && $allnumFailedLessThanMaxNumResubmission > 0);
	
	if ($verbose) {
		print "CHECK: current content of $paraStatusFile\n"; 
		system("cat $paraStatusFile");
	}

	return ($allDone, $allnumRun, $allnumPend, $allnumFailed, $allnumDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, \@jobIDsFailedLessThanMaxNumResubmission);
}

#####################################################
# test if the given job crashed because it reached the run time limit of this queue
# by checking if "TERM_RUNLIMIT: job killed after reaching LSF run time limit" occurs in the output file
#####################################################
sub doesCrashedJobReachedRuntimeLimit {
	my ($jobID,$jobName) = @_;

	my $filename = ".para/$jobName";
	
	# test if that file exists and is non-empty
	die "######### ERROR ######### in doesCrashedJobReachedRuntimeLimit: output file $filename does not exist or is empty for $jobID\n" if (! -s $filename);

	# ------------------------------------------------------------
	# LSBATCH: User input
	# sh -c "./filter.csh input.gz output.gz"
	# ------------------------------------------------------------
	#
	# TERM_RUNLIMIT: job killed after reaching LSF run time limit.
	# Exited with exit code 140.
	# 
	# Resource usage summary:
	open (fileOutput, "$filename") || die "######### ERROR #########: cannot read $filename\n";
	my @content = <fileOutput>;
	chomp(@content);
	close fileOutput;
	
	# sanity check: second line should contain the jobID
	print STDERR "######### ERROR ######### in doesCrashedJobReachedRuntimeLimit: cannot find the jobID ($jobID) in the second line of $filename: $content[1]\n" if ($content[1] !~ /Subject: Job $jobID:/);

	foreach my $line (@content) {
		if ($line =~ /TERM_RUNLIMIT: job killed after reaching LSF run time limit/) {
			# job reached the runtime limit --> return 1
			return 1; 
		}
		
		# stop parsing if this string occurs
		if ($line =~ /^Resource usage summary/) {
			last;
		}
	}   

	# job did not reach the limit and crashed for other reasons
	return 0;
}

#####################################################
# Push failed jobs again until they failed $maxNumResubmission times. 
#####################################################
sub pushCrashed {
	my $crashedJobIDs = shift;			# this is a pointer to an array of crashed jobIDs generated by check()
	getLock();

	# read the bsub parameters
	open (filePara, "$paraBsubParaFile") || die "######### ERROR #########: cannot read $paraBsubParaFile\n";
	my $allotherbsubParameters = <filePara>;			# contains the queue and additional stuff
	chomp ($allotherbsubParameters);
	close filePara;

   # now read all jobs from $paraJobsFile into a hash, as we have to update the jobIDs
	open (fileJobs, "$paraJobsFile") || die "######### ERROR #########: cannot read $paraJobsFile\n";
	print "\tPUSHCRASHED: reading $paraJobsFile .... " if ($verbose);
	my %jobID2job;
	my %jobID2name;
	my %jobID2queue;
	my $line = "";
	while ($line = <fileJobs>) {
		chomp($line);

		# format is $jobID $jobName $queue $job			(e.g. 513650	test/1/o.50	short	tests/DieRandom.perl -T 0.9 > out/15.txt)
		my ($jobID, $jobName, $queue, $job) = (split(/\t/, $line))[0,1,2,3];
		$jobID2job{$jobID} = $job;
		$jobID2name{$jobID} = $jobName;
		$jobID2queue{$jobID} = $queue;
	}
   close fileJobs;
	print "DONE\n" if ($verbose);
	
	# now push all crashed jobs again
	# store the conversion oldID -> newID in a hash
	my %oldID2newID;
	my $numJobsPushedAgain = 0;
	for (my $i=0; $i < scalar @{$crashedJobIDs}; $i++) {
		my $oldID = $crashedJobIDs->[$i];
		my $job = $jobID2job{$oldID};
		my $jobName = $jobID2name{$oldID};
		my $queueForThisJob = $jobID2queue{$oldID};
		
		print "\tPUSHCRASHED:  push again failed job with ID $oldID to queue $queueForThisJob: $job\n" if ($verbose);

		# test if this job crashed because it reached the LSF run time limit for the specified queue
		# if this is the case, push the job to next longer queue
		if (doesCrashedJobReachedRuntimeLimit($oldID, $jobName) == 1) {
			# get the next longest queue in case of reaching the runtime limit
			print "\t\tPUSHCRASHED: job $oldID reached runtime limit of $queueForThisJob and is now pushed to " if ($verbose);
			if ($queueForThisJob ne $maxRunTimeQueue) {
				# only set the queue to the next longest queue if this parameter is not given
				if ($resubmitToSameQueueIfQueueMaxTimeExceeded == 0) {
					$queueForThisJob = $Order2Queue{ $Queue2Order{$queueForThisJob} + 1 }; 
				}
			}else{
				print STDERR "ERROR: job $oldID reached runtime limit of $queueForThisJob which is the maximum runtime queue !! --> Will push again to the same queue. \n";
			}
			print "$queueForThisJob\n" if ($verbose);
		}

		# remove the outputfile
		system("rm -f ./.para/$jobName");

		# push	
		my $newID = pushSingleJob("-q $queueForThisJob $allotherbsubParameters -o ./.para/$jobName", $job);
		$oldID2newID{$oldID} = $newID;

		# update the jobID for the $paraJobsFile file
		delete $jobID2job{$oldID};
		$jobID2job{$newID} = $job;
		delete $jobID2name{$oldID};
		$jobID2name{$newID} = $jobName;
		delete $jobID2queue{$oldID};
		$jobID2queue{$newID} = $queueForThisJob;
		print "\tPUSHCRASHED:   --> new ID $newID\n" if ($verbose);

		$numJobsPushedAgain ++;
	}

	# write the new $paraJobsFile file that has the up-to-date jobIDs
	backup();
	open (fileJobs, ">$paraJobsFile") || die "######### ERROR #########: cannot create $paraJobsFile\n";
	print "\tPUSHCRASHED: write updated jobIDs to $paraJobsFile .... " if ($verbose);
	foreach my $jobID (sort keys %jobID2job) {
		print fileJobs "$jobID\t$jobID2name{$jobID}\t$jobID2queue{$jobID}\t$jobID2job{$jobID}\n";
	}
   close fileJobs;
	print "DONE\n" if ($verbose);

	# read the $paraStatusFile file
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my @oldStatus = <fileStatus>;
	chomp(@oldStatus);
	close fileStatus;

	# now clobber the $paraStatusFile file and update 
	# every repushed job gets the new ID and gets status PEND. Runtime is set to -1
	open (fileStatus, ">$paraStatusFile") || die "######### ERROR #########: cannot create $paraStatusFile\n";
	print "\tPUSHCRASHED: update $paraStatusFile .... \n" if ($verbose);
	for (my $i=0; $i<=$#oldStatus; $i++) {
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $oldStatus[$i]))[0,1,2,3,4];
		if (exists $oldID2newID{$jobID}) { 
			my $newStatus = "$oldID2newID{$jobID}\t$jobName\tPEND\t$howOftenFailed\t-1";
			print "\t\tPUSHCRASHED: OLD $oldStatus[$i]\n\t\tPUSHCRASHED: NEW $newStatus\n" if ($verbose);
			print fileStatus "$newStatus\n";
		}else{
			# a job that we have not touched
			print fileStatus "$oldStatus[$i]\n";	
		}
	}
	close fileStatus;
	print "\tPUSHCRASHED: DONE\n" if ($verbose);

	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	print "--> $numJobsPushedAgain jobs crashed and were pushed again\n";
}

#####################################################
# wait until the joblist is done. Push failed jobs again until they failed $maxNumResubmission times. 
#####################################################
sub waitForJobs {

	print "WAIT UNTIL jobList is finished ..... \n";

	# number of sleep cycles. Used to increase the cycle length after a $\
	my $noSleepCycles = 0;
	
	# count how long we are waiting
	my $totalWaitTime = 0;
	
	while (1) {
		# for sanity purpose only
		checkIfInternalFilesExist($jobListName);
		
		# now check how many are done
		# allDone is a flag: 1 == all done, 0 == some run/pend/failed, -1 == some jobs failed repeatedly but all others are done, -2 == all jobs finished or crashed but the crashed ones can be resubmitted
		my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $numFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
		printf "numJobs: %-7d\tRUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d  (%d of them failed $maxNumResubmission times)\tallDone: %s\n", $numJobs,$numRun,$numPend,$numDone,$numFailed,$numFailed-$numFailedLessThanMaxNumResubmission,($allDone == 1 ? "YES" : "NO");	
		
		if ($allDone == 1) {
			print "*** ALL JOBS SUCCEEDED ***\n";
			last;
		}elsif ($allDone == -1) {
			print "*** CRASHED. Some jobs failed $maxNumResubmission times !!  Run 'para crashed' to list those failed jobs. ***\n";
			last;
		}
		
		# push crashed jobs again, if some failed less than $maxNumResubmission times
		pushCrashed($jobIDsFailedLessThanMaxNumResubmission) if ($numFailedLessThanMaxNumResubmission > 0);

		# sleep. At the beginning we sleep only a minute, after 10 minutes, we sleep 3 minutes. All are parameters
		if ($noSleepCycles >= $maxNumFastSleepCycles) {
			print "sleep $sleepTime2 seconds ...  (waiting $totalWaitTime sec by now)\n";
			$totalWaitTime += $sleepTime2;
			sleep($sleepTime2);
		}else{
			print "sleep $sleepTime1 seconds ...  (waiting $totalWaitTime sec by now)\n";
			$totalWaitTime += $sleepTime1;
			sleep($sleepTime1);
		}
		$noSleepCycles ++;
	}	

	printf "totalWaitTime waited: %d sec  ==  %1.1f min  ==  %1.1f h  ==  %1.1f days\n", $totalWaitTime, $totalWaitTime/60, $totalWaitTime/60/60, $totalWaitTime/60/60/24; 

}	

#####################################################
# run bjobs and parse
#####################################################
sub runbjobs {
	my ($IDstring, $jobID2jobName) = @_;
	
	# sanity check: We should get one result line from bjobs for every given ID. If not, we are losing jobs. 
	# we put all returned jobIDs in a hash and check at the end if all IDs have been returned
	my %jobIDsSeen;
		
	# new feature: bjobs fails with "Job <505743> is not found" if the job is too 'old'
	# in the call below, we catch both stdout and stderr
	# we do not test if bjobs returns a non-zero exit code but rather parse the lines listing errors below
	my $call = "bjobs $IDstring 2>&1 | cat "; 
	print "\tRUNBJOBS: $call\n" if ($verbose);

	# in rare cases LSF is so busy that "LSF is processing your request. Please wait" appears --> then wait 3 minutes and try again in an endless loop
	my @res ;
	while (1) {
		@res = `$call`;
		chomp(@res);
		
		if ($res[0] =~ /^LSF is processing your request. Please wait/) {
			print "\t\trunbjobs got message from running 'bjobs [ID list]' \"$res[0]\": --> wait 3 minutes and run again\n";
			sleep($sleepTimeLSFBusy);
		}else{
			last;		# leave the loop if there is real data
		}
	}
		
	# parse something like 
	# JOBID   USER	STAT  QUEUE	  FROM_HOST   EXEC_HOST   JOB_NAME   SUBMIT_TIME
	# 363772  hiller  RUN   short	  madmax	  n16		 test_3	 Apr 23 15:42
	# 363773  hiller  EXIT  short	  madmax	  n14		 test_4	 Apr 23 15:42
	# Job <505743> is not found
	my $parajob = "";	   # string holding "JobID status numfailed runtime" 
	my $numRun = 0;
	my $numPend = 0;
	my $numFailed = 0;
	my $numDone = 0;
	foreach my $line (@res) {
		next if ($line =~ /^JOBID/);		# skip header line
		
		print "\t\tRUNBJOBS current line: $line\n" if ($verbose);
		my $jobID = -1;
		my $status = "";
		my $runTime = -1;
		my $jobName = "";
		# if bjobs does not find the job anymore --> parse the output file
		if ($line =~ /^Job <(\d+)> is not found/) {
			$jobID = $1;
			$jobIDsSeen{$jobID} = 1;
			print "\t\tRUNBJOBS bjobs cannot find job $jobID ($line) --> job must be DONE or EXIT --> Parse the status from its output file\n" if ($verbose);
			($jobName,$status,$runTime) = getStatusFromOutputFile($jobID, $jobID2jobName); 
			print "\t\t\tRUNBJOBS GET $status $runTime $jobName for $jobID from file\n" if ($verbose);
			# pass the runtime to check(). 
			# NOTE: we leave the $howOftenFailed to 0, because it case the job is EXIT, check() will increase the times-failed based on the old counter (read from $paraStatusFile)
			$parajob .= "$jobID\t$jobName\t$status\t0\t$runTime\n";

		# we test if the username and $clusterHeadNode appears in the line. Then it is a regular line like
		# 595742  hiller  DONE  short      madmax      n01         mytest     May  4 12:54
		}elsif ($line =~ /\W+$user\W.*$clusterHeadNode/) {
			($jobID, $status) = (split(/\W+/, $line))[0,2];
			$jobIDsSeen{$jobID} = 1;
			print "\t\tRUNBJOBS bjobs returns: $jobID $status\t(from outputline $line)\n" if ($verbose);
			print "\t\t\tRUNBJOBS GET $status $runTime from line $line\n" if ($verbose);
			$parajob .= "$jobID\tdummyName\t$status\t0\t-1\n";

		}else{
			print STDERR "######### ERROR ######### in RUNBJOBS: cannot parse this line returned from bjobs: $line\n";
			print STDERR "######### ERROR ######### in RUNBJOBS: Here is the full output from $call .... \n";
			$" = "\n\t";
			print STDERR "@res\n";
			print STDERR "######### ERROR ######### in RUNBJOBS: .... end of full output from this bjobs run\n";
		}
		$numRun ++ if ($status eq "RUN");
		$numPend ++ if ($status eq "PEND");
		$numFailed ++ if ($status eq "EXIT");
		$numDone ++ if ($status eq "DONE");
	}
		
	print "\tRUNBJOBS result:	 RUN: $numRun\t\tPEND: $numPend\t\tDONE: $numDone\t\tFAILED: $numFailed	  and as the following status lines...\n$parajob\n" if ($verbose);
	
	# now check if all given IDs were returned by bjobs
	foreach my $ID (split(/ /, $IDstring)) {
		print STDERR "######### ERROR ######### in runbjobs: $ID was given in the input but bjobs did not return anything for that ID\n" if (! exists $jobIDsSeen{$ID});
	}
	
	return ($parajob, $numRun, $numPend, $numFailed, $numDone);
}
	
	
#####################################################
# get the status and runtime of a job from its output file. This fct is used when bjobs does not find the job anymore.
#####################################################
sub getStatusFromOutputFile {
	my ($jobID, $jobID2jobName) = @_;
	
	# get jobName --> determines the output file
	die "######### ERROR ######### in getStatusFromOutputFile: cannot determine the jobName for $jobID from the hash\n" if (! exists $jobID2jobName->{$jobID});
	my $jobName = $jobID2jobName->{$jobID};
	my $filename = ".para/$jobName";
	
	# test if that file exists and is non-empty
	die "######### ERROR ######### in getStatusFromOutputFile: output file $filename does not exist or is empty for $jobID\n" if (! -s $filename);

	# parse something like
	# Job <mytest> was submitted from host <madmax> by user <hiller> in cluster <>.
	# Job was executed on host(s) <n16>, in queue <short>, as user <hiller> in cluster <>.
	# </home/hiller> was used as the home directory.
	# </projects/Test> was used as the working directory.
	# Started at Sat May  4 12:54:15 2013
	# Results reported at Sat May  4 12:55:01 2013
	# 
	# Your job looked like:
	# ------------------------------------------------------------
	# LSBATCH: User input
	# tests/DieRandom.perl -T 0.9 > out/9.txt
	# ------------------------------------------------------------
	# Successfully completed.
	# Resource usage summary:
	open (fileOutput, "$filename") || die "######### ERROR #########: cannot read $filename\n";
	my @content = <fileOutput>;
	chomp(@content);
	close fileOutput;
	
	# sanity check: second line should contain the jobID
	print STDERR "######### ERROR ######### in getStatusFromOutputFile: cannot find the jobID ($jobID) in the second line of $filename: $content[1]\n" if ($content[1] !~ /Subject: Job $jobID:/);

	print "\t\tgetStatusFromOutputFile: try to get status and runtime for $jobID from file $filename, which contains:\n", `cat $filename` if ($verbose);

	# get status, start and endtime
	my $startTime = "-1";
	my $endTime = "-1";
	my $status = "";
	foreach my $line (@content) {
		if ($line =~ /^Started at (.+)/) {
			$startTime = ParseDate($1);
			print "\t\t\tgetStatusFromOutputFile: found starttime $startTime in line $line\n" if ($verbose);
		}elsif ($line =~ /^Results reported at (.+)/) {
			$endTime = ParseDate($1);
			print "\t\t\tgetStatusFromOutputFile: found endtime $endTime in line $line\n" if ($verbose);
 		}elsif ($line =~ /^Successfully completed.$/) {
			$status = "DONE"
		}elsif ($line =~ /^Exited with exit code/) {
			$status = "EXIT";
		}
		
		# stop parsing if this string occurs
		if ($line =~ /^Resource usage summary/) {
			last;
		}
	}   

	die "######### ERROR ######### in getStatusFromOutputFile: cannot determine DONE or EXIT status from $filename (status is $status)\n" if (! ($status eq "DONE" || $status eq "EXIT"));
	die "######### ERROR ######### in getStatusFromOutputFile: cannot parse the startime from $filename\n" if ($startTime eq "-1");
	die "######### ERROR ######### in getStatusFromOutputFile: cannot parse the endtime from $filename\n" if ($endTime eq "-1");

	# we only need to calc the runtime if the job finished
	my $runTime = -1;
	if ($status eq "DONE") {
		my $startTimeSec = UnixDate($startTime,'%s');
		my $endTimeSec = UnixDate($endTime,'%s');
		$runTime = $endTimeSec - $startTimeSec;
		die "######### ERROR #########: getStatusFromOutputFile: runTime is < 0 seconds for job $jobID from file $filename: $runTime = $endTimeSec - $startTimeSec \n" if ($runTime < 0);
		# if the runtime is really 0, return 1 sec
		$runTime = 1 if ($runTime == 0);
	}
	print "\t\t\tgetStatusFromOutputFile: Job $jobID file $filename gives status $status and runtime $runTime ($startTime .. $endTime)\n" if ($verbose);

	return ($jobName, $status, $runTime);

}

#####################################################
# recover the crashed jobs and write them to the given output file
#####################################################
sub crashed {

	my $outjobListFile = $ARGV[2];
	print "\tCRASHED: recover jobIDs of crashed jobs\n" if ($verbose);

	# update $paraStatusFile
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();

	getLock();

	# get all crashed jobIDs from $paraStatusFile
	# create a hash that lists these jobIDs
	my %crashedJobIDs;
	my $numCrashed = 0;
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my $line = "";
	while ($line = <fileStatus>) {
		chomp($line);

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $line))[0,1,2,3,4];
		if ($status eq "EXIT") {
			print "\t\tCRASHED: $line\n" if ($verbose);
			$crashedJobIDs{$jobID} = 1;
			$numCrashed ++;
		}
	}
   close fileStatus;
	print "\tCRASHED: found $numCrashed jobIDs that crashed\n" if ($verbose);

   # now read all jobs from $paraJobsFile and output the crashed ones into the output file
	open (fileJobs, "$paraJobsFile") || die "######### ERROR #########: cannot read $paraJobsFile\n";
	open (fileOut, ">$outjobListFile") || die "######### ERROR #########: cannot create $outjobListFile\n";
	print "\tCRASHED: open $outjobListFile\n" if ($verbose);
	while ($line = <fileJobs>) {
		chomp($line);

		# format is $jobID $jobName $job
		my ($jobID, $jobName, $queue, $job) = (split(/\t/, $line))[0,1,2,3];
		if (exists $crashedJobIDs{$jobID}) {
			print "\t\tCRASHED: crashed job $job	(line from $paraJobsFile: $line)\n" if ($verbose);
			print fileOut "$job\n";
		}
	}
   close fileJobs;
	close fileOut;
	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	print "recovered $numCrashed crashed jobs into $outjobListFile\n";
}



#####################################################
# kills all pending jobs if "chill" is given
# kills all pending AND running jobs if "stop" is given
#####################################################
sub killJobs {
	my $mode = shift; 		# is either stop or chill

	print "\tKILLJOBS: mode $mode\n" if ($verbose);

	# update $paraStatusFile
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();

	getLock();

	# get all jobIDs and their status from $paraStatusFile
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my $line = "";
	while ($line = <fileStatus>) {
		chomp($line);

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $line))[0,1,2,3,4];
		if ($status eq "PEND") {
			print "\t\tKILL pending job: $line\n" if ($verbose);
			system "bkill $jobID" || print "######### ERROR #########: 'bkill $jobID' caused an error. Did the job already finish ?";	
		}elsif ($status eq "RUN" && $mode eq "stop") {
			print "\t\tKILL running job: $line\n" if ($verbose);
			system "bkill $jobID" || print "######### ERROR #########: 'bkill $jobID' caused an error. Did the job already finish ?";	
		}
	}   
	close fileStatus;
	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	print "$numPend pending ", ($mode eq "stop" ? "and $numRun running " : ""), "jobs killed\n";
}


#####################################################
# get run times of all running and done jobs. Estimate when the jobList will be finished
#####################################################
sub gettime {
	print "\tGETTIME:\n" if ($verbose);

	# update $paraStatusFile
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();
	
	getLock();
	
	# get current time. We need that to subtract from the job's start time to get the delta.
	my $curTime = ParseDate(`date`);
	die "######### ERROR ######### in gettime: calling 'date' failed with exit code $?\n" if ($? != 0);
	print "\tGETTIME: current time: $curTime\n" if ($verbose);


 
	# read the $paraStatusFile file
	# if a job is running, get the current run time
	# if a job is finished, read the total run time for that job from the file OR if not given, get the total run time
	# then update $paraStatusFile and calculate the stats
  	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my @oldStatus = <fileStatus>;
	chomp(@oldStatus);
	close fileStatus;
	#	
	if ($verbose) {
		$" = "\n\t"; print "\t\tGETTIME: old Status array:\n\t@oldStatus\n";
	}

	my $newStatus = "";	# string that contains the new content of $paraStatusFile
	my @timesFinished;	# runtimes of finished jobs
	my @timesRunning;		# current runtimes of running jobs
	my $runTimeLongestRunningJob = -1;			# runtime of longest running job
	my $jobIDMaxRunTimeRunning = -1;				# jobID of this job
	my $runTimeLongestFinishedJob = -1;			# runtime of longest finished job
	my $jobIDMaxRunTimeFinished = -1;			# jobID of this job
	for (my $i=0; $i<=$#oldStatus; $i++) {

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $oldStatus[$i]))[0,1,2,3,4];

		# just copy pending or crashed jobs
		if ($status eq "EXIT" || $status eq "PEND") {
			$newStatus .= "$oldStatus[$i]\n";
			print "\t\tGETTIME: skip $oldStatus[$i]\n" if ($verbose);

		}elsif ($status eq "DONE") {
			# the runtime of a DONE job gets only written or updated in $paraStatusFile if you call gettime. 
			# check() does not update but writes -1 for all jobs that finished, expect those that finished before and had a correct runtime already given. 
			# therefore we have to get the runtime, if the given runtime in the file is -1. 
			# Once we put the correct runtime in the $paraStatusFile file, we never have to get it again with bjobs -l
			print "\t\tGETTIME: finished job $oldStatus[$i]\n" if ($verbose);
			# NOTE: With the new implementation, where check() calls getRunTime() as soon as a job finished, it should not happen anymore that runTime is -1
			if ($runTime == -1) {
				$runTime = getRunTime($jobID, $curTime);
			}
			push @timesFinished, $runTime;
			$newStatus .= "$jobID\t$jobName\t$status\t$howOftenFailed\t$runTime\n";
			# longest finished job
			if ($runTimeLongestFinishedJob < $runTime) {
				$runTimeLongestFinishedJob = $runTime;
				$jobIDMaxRunTimeFinished = $jobID;	
			}

		}elsif ($status eq "RUN") {
			# we always measure the runtime of currently running jobs again
			print "\t\tGETTIME: running job $oldStatus[$i]\n" if ($verbose);
			$runTime = getRunTime($jobID, $curTime);
			push @timesRunning, $runTime;
			$newStatus .= "$jobID\t$jobName\t$status\t$howOftenFailed\t$runTime\n";

			# longest running job
			if ($runTimeLongestRunningJob < $runTime) {
				$runTimeLongestRunningJob = $runTime;
				$jobIDMaxRunTimeRunning = $jobID;	
			}
	
		}else {		# sanity check
			die "######### ERROR ######### in gettime: unknown status: $oldStatus[$i]\n$paraStatusFile is not altered.";
		}
	}

	# now update $paraStatusFile with the new runtimes
 	backup();
	open (fileStatus, ">$paraStatusFile") || die "######### ERROR #########: cannot write $paraStatusFile\n";
	print fileStatus "$newStatus";
	close fileStatus;

	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	# now calculate the stats and print
	my $ave = -1;
	my $sum = -1;
	$sum = getSum(@timesFinished) if ($#timesFinished >= 0);
	$ave = $sum / (scalar @timesFinished) if ($#timesFinished >= 0);
	printf "RUN: %-7d\tPEND: %-7d\tDONE: %-7d\tFAILED: %-7d\n", $numRun,$numPend,$numDone,$numFailed;	
	if ($ave == -1) {
		printf "%-25s NO job finished. No estimate.\n", "Average job time:";	
	}else{
		printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\n", "Time in finished jobs:", $sum, $sum/60, $sum/60/60, $sum/60/60/24;
		printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\n", "Average job time:", $ave, $ave/60, $ave/60/60, $ave/60/60/24;
	}
	printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\t\t(jobID $jobIDMaxRunTimeFinished)\n", "Longest finished job:", $runTimeLongestFinishedJob, $runTimeLongestFinishedJob/60, $runTimeLongestFinishedJob/60/60, $runTimeLongestFinishedJob/60/60/24 if ($runTimeLongestFinishedJob > 0);
	printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\t\t(jobID $jobIDMaxRunTimeRunning)\n", "Longest running job:", $runTimeLongestRunningJob, $runTimeLongestRunningJob/60, $runTimeLongestRunningJob/60/60, $runTimeLongestRunningJob/60/60/24 if ($runTimeLongestRunningJob > 0);
	# estimated time to completion == $ave * ($numPend + $numRun) / $numRun
	# we assume here that the running and pending jobs will have a similar run time and that we will continue to use the same number cores ($numRun)
	# this estimate is conservative in that all running jobs are assumed to take $ave time to completion (ignores that they are running already)
	if ($allDone == 1) {
		print "*** ALL JOBS SUCCEEDED ***\n";
	}elsif ($allDone == -1) {
		print "*** CRASHED. Some jobs failed $maxNumResubmission times !!  Run 'para crashed' to list those failed jobs. ***\n";
	}else {
		if ($numRun == 0) {
			printf "%-25s INFINITE as no jobs are running but only $numDone of $numJobs succeeded\n", "Estimated complete:";
		}else{
			my $estimatedComplete = $ave * ($numPend + $numRun) / $numRun;
			printf "%-25s %9.0f sec\t%8.1f min\t%6.1f h\t%5.1f days\t\t(assume $numRun running jobs)\n", "Estimated complete:", $estimatedComplete, $estimatedComplete/60, $estimatedComplete/60/60, $estimatedComplete/60/60/24;;
		}
	}
}

#####################################################
# get run times of a job, given its jobID
#####################################################
sub getRunTime {
	my ($jobID, $curTime) = @_;

	print "\t\tGETRUNTIME for $jobID\n" if ($verbose);

	# run bjobs -l and parse
	# 
	# Job <418479>, Job Name <test>, User <hiller>, Project <default>, Status <EXIT>,
	#					   Queue <short>, Command <sleep 70; echo hallo > out2>, Sh
	#					  	are group charged </hiller>
	# Mon Apr 29 17:41:28: Submitted from host <madmax>, CWD </projects/Test>;
	# Mon Apr 29 17:41:42: Started on <n20>, Execution Home </home/hiller>, Execution
	#					CWD </projects/Test>;
	# Mon Apr 29 17:42:13: Done successfully. The CPU time used is 0.0 seconds.
	# 
	# NOTE: if you take several cores that line might look like
	# Wed Nov 27 10:31:45: Started on 10 Hosts/Processors <10*n32>, Execution Home </
	# --> the regular expression below has been adapted to cover both cases

	# in rare cases LSF is so busy that "LSF is processing your request. Please wait" appears --> then wait 3 minutes and try again in an endless loop
	my @result;
	while (1) {
		@result = `bjobs -l $jobID 2>&1 | cat `;
		chomp(@result);
		if ($result[0] =~ /^LSF is processing your request. Please wait/) {
			print "\t\tgetRunTime got message from running 'bjobs -l $jobID' \"$result[0]\": --> wait 3 minutes and run again\n";
			sleep($sleepTimeLSFBusy);
		}else{
			last;		# leave the loop if there is real data
		}
	}
		
	die "######### ERROR ######### in getRunTime: bjobs -l $jobID failed with exit code $?\n" if ($? != 0);
	# NOTE: if bjobs does not find the job anymore, it still exits with 0 !! 
	# Above we are mixing STDERR (only stream that delivers anything in case of an error) with STDOUT (only stream that delivers anything in case of NO error). 
	# This allows us to test if the first line contains an error message. 
	if ($result[0] =~ /Job <.+> is not found/) {
		print "Using the slower bhist -n0 to get the runtime for $jobID\n";
		return getRunTimeBhist($jobID, $curTime);
	}
	
	# sanity check
	print STDERR "######### ERROR #########: cannot find the string 'Job <$jobID>' in line $result[1]\n" if ($result[1] !~ /^Job <$jobID>,/);

	my $startTime = "-1";
	my $endTime = "-1";
	foreach my $line (@result) {
		chomp($line);
		if ($line =~ /^(.+): Started on.*<.+>/) {
			$startTime = ParseDate($1);
			print "\t\t\tGETRUNTIME: found starttime $startTime in line $line\n" if ($verbose);
		}elsif ($line =~ /^(.+): Done successfully. The CPU/) {
			$endTime = ParseDate($1);
			print "\t\t\tGETRUNTIME: found endtime $endTime in line $line\n" if ($verbose);
 		} 
		
		# stop parsing if this string occurs
		if ($line =~ /^ SCHEDULING PARAMETERS/) {
			last;
		}

		# sanity check. 
		if ($line =~ /Exited by signal/) {
			print STDERR "######### ERROR #########: Looks like the job failed. I find 'Exited by signal' in $line\n";
		}
	}

	$" = "\n";
	die "######### ERROR #########: GETRUNTIME: cannot parse the startime from 'bjobs -l $jobID' which gives @result\n" if ($startTime eq "-1");

	# convert to unix date (second) and get the runtime
	my $startTimeSec = UnixDate($startTime,'%s');
	my $endTimeSec = -1;
	# no end time found. Then job must be still running. Use $curTime as $endTime
	if ($endTime eq "-1") {
		$endTime = $curTime;
		print "\t\t\tGETRUNTIME: Job $jobID: using current time as endtime: $curTime\n" if ($verbose);
	}
	$endTimeSec = UnixDate($endTime,'%s');
	
	my $runTime = $endTimeSec - $startTimeSec;
	die "######### ERROR #########: GETRUNTIME: runTime is < 0 seconds for job $jobID : $runTime = $endTimeSec - $startTimeSec \n" if ($runTime < 0);
	# if the runtime is really 0, return 1 sec
	$runTime = 1 if ($runTime == 0);
	print "\t\t\tGETRUNTIME: Job $jobID:  $startTime .. $endTime is in seconds   $startTimeSec .. $endTimeSec = $runTime runtime seconds\n" if ($verbose);

	return $runTime;
}


#####################################################
# get run times of a job, given its jobID
# in contrast to to getRunTime() it uses the much slower bhist -n0 -l
# We call this function if bjobs cannot find the job anymore
#####################################################
sub getRunTimeBhist {
	my ($jobID, $curTime) = @_;

	print "\t\tGETRUNTIMEBHIST for $jobID\n" if ($verbose);

	# run bhist -n0 -l and parse
	# 
	# Job <452410>, Job Name <test>, User <hiller>, Project <default>, Command <echo 
 	#                 hallo > out>
	# Wed May  1 15:25:48: Submitted from host <madmax>, to Queue <short>, CWD </proj
	#                      ects/Test>;
	# Wed May  1 15:25:52: Dispatched to <n16>;
	# Wed May  1 15:25:52: Starting (Pid 63409);
	# Wed May  1 15:25:52: Running with execution home </home/hiller>, Execution CWD 
	#                      </projects/Test>, Execution Pid <6340
	#                      9>;
	# Wed May  1 15:25:52: Done successfully. The CPU time used is 0.0 seconds;
	# Wed May  1 15:25:52: Post job process done successfully;
	# 
	# Summary of time in seconds spent in various states by  Wed May  1 15:25:52
	#   PEND     PSUSP    RUN      USUSP    SSUSP    UNKWN    TOTAL
	#   4        0        0        0        0        0        4           
   my @result = `bhist -n0 -l $jobID 2>&1 | cat `;
	die "######### ERROR ######### in getRunTime: bhist -n0 -l $jobID failed with exit code $?\n" if ($? != 0);
	# NOTE: if bhist does not find the job anymore, it still exits with 0 !! 
	# Above we are mixing STDERR (only stream that delivers anything in case of an error) with STDOUT (only stream that delivers anything in case of NO error). 
	# This allows us to test if the first line contains an error message ($result[0] should be an empty line)
	if ($result[0] =~ /Job <.+> is not found/ || $result[0] ne "\n") {
		die "######### ERROR #########: GETRUNTIMEBHIST failed for $jobID calling: bhist -n0 -l $jobID 2>&1 | cat   which gives @result\n";
	}
	
	# sanity check
	print STDERR "######### ERROR #########: cannot find the string 'Job <$jobID>' in line $result[1]\n" if ($result[1] !~ /^Job <$jobID>,/);

	my $startTime = "-1";
	my $endTime = "-1";
	foreach my $line (@result) {
		chomp($line);
		if ($line =~ /^(.+): Starting \(Pid /) {
			$startTime = ParseDate($1);
			print "\t\t\tGETRUNTIMEBHIST: found starttime $startTime in line $line\n" if ($verbose);
		}elsif ($line =~ /^(.+): Done successfully. The CPU/) {
			$endTime = ParseDate($1);
			print "\t\t\tGETRUNTIMEBHIST: found endtime $endTime in line $line\n" if ($verbose);
 		} 
		
		# stop parsing if this string occurs
		if ($line =~ /^ SCHEDULING PARAMETERS/) {
			last;
		}

		# sanity check. 
		if ($line =~ /Exited by signal/) {
			print STDERR "######### ERROR #########: Looks like the job failed. I find 'Exited by signal' in $line\n";
		}
	}

	$" = "\n";
	die "######### ERROR #########: GETRUNTIMEBHIST: cannot parse the startime from 'bhist -n0 -l $jobID' which gives @result\n" if ($startTime eq "-1");

	# convert to unix date (second) and get the runtime
	my $startTimeSec = UnixDate($startTime,'%s');
	my $endTimeSec = -1;
	# no end time found. Then job must be still running. Use $curTime as $endTime
	if ($endTime eq "-1") {
		$endTime = $curTime;
		print "\t\t\tGETRUNTIMEBHIST: Job $jobID: using current time as endtime: $curTime\n" if ($verbose);
	}
	$endTimeSec = UnixDate($endTime,'%s');
	
	my $runTime = $endTimeSec - $startTimeSec;
	die "######### ERROR #########: GETRUNTIMEBHIST: runTime is < 0 seconds for job $jobID : $runTime = $endTimeSec - $startTimeSec \n" if ($runTime < 0);
	# if the runtime is really 0, return 1 sec
	$runTime = 1 if ($runTime == 0);
	print "\t\t\tGETRUNTIMEBHIST: Job $jobID:  $startTime .. $endTime is in seconds   $startTimeSec .. $endTimeSec = $runTime runtime seconds\n" if ($verbose);

	return $runTime;
}

#####################################################
# delete all para and LSF output files for $jobListName
#####################################################
sub clean {

	# update $paraStatusFile
	my ($allDone, $numRun, $numPend, $numFailed, $numDone, $numJobs, $allnumFailedLessThanMaxNumResubmission, $jobIDsFailedLessThanMaxNumResubmission) = check();

	die "######### ERROR #########: you still have $numRun running and $numPend pending jobs. Before cleaning, you have to run 'para stop $jobListName' to stop all jobs.\n" if ($numRun > 0 || $numPend > 0);

	getLock();

	# get all jobNames and remove .para/$jobName
	open (fileStatus, "$paraStatusFile") || die "######### ERROR #########: cannot read $paraStatusFile\n";
	my $line = "";
	while ($line = <fileStatus>) {
		chomp($line);

		# format is $jobID $jobName $status $howOftenFailed $runTime
		my ($jobID, $jobName, $status, $howOftenFailed, $runTime) = (split(/\t/, $line))[0,1,2,3,4];
		system("rm -f ./.para/$jobName");
	}   
	close fileStatus;
	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	system("rm -f $paraStatusFile $paraJobsFile $paraBsubParaFile $paraJobNoFile $paraStatusFilebackup* $paraJobsFilebackup* $paraBsubParaFilebackup*");
	system("rm -rf ./.para/$jobListName");
	
	# delete .para/backup directory if it is empty
	if (-d ".para/backup") {
		system ("rmdir .para/backup") if (`ls .para/backup | wc -l` eq "0\n"); 
	}

	# delete .para directory if it is empty
	system ("rmdir .para") if (`ls .para/ | wc -l` eq "0\n"); 

	print "jobList $jobListName is cleaned\n";
}

=pod
#####################################################
# restore the .para/.para.*.$jobListName files from the backup files
#####################################################
sub restore {

	die "The restore() function is currently disabled as we are storing all backup files in the .para/backup/ dir right now
Please look into .para/backup/ and get the version that still has uncorrupted data (highest version numbers are most recent data)
Then copy the respective backup files to $paraStatusFile $paraJobsFile $paraBsubParaFile
Version 0 refers to the files that have been created right during the first submission of the jobs
";

	if (! -e "$paraStatusFile.backup" || ! -e "$paraJobsFile.backup" || ! -e "$paraBsubParaFile.backup") {
		die "######### ERROR #########: cannot restore the backup files as they don't exist: $paraStatusFile.backup $paraJobsFile.backup $paraBsubParaFile.backup\n" 
	}
	
	getLock();

	system("mv $paraStatusFile.backup $paraStatusFile");
	system("mv $paraJobsFile.backup $paraJobsFile");
	system("mv $paraBsubParaFile.backup $paraBsubParaFile");

	system "rm -f ./lockFile.$jobListName" || die "######### ERROR #########: cannot delete ./lockFile.$jobListName";	

	print "Successfully restored the internal .para files for jobList $jobListName\n";
}
=cut

#####################################################
# make a backup copy with version number 0 that refers to these original files
#####################################################
sub firstBackup {
	return if ($keepBackupFiles == 0);

	my $endNumber = 0;
	system("cp $paraStatusFile $paraStatusFilebackup$endNumber"); 
	system("cp $paraJobsFile $paraJobsFilebackup$endNumber");
	system("cp $paraBsubParaFile $paraBsubParaFilebackup$endNumber");
}

#####################################################
# backup the .para/.para.*.$jobListName files
# new feature: we backup every time and store the files with a unique end number
#####################################################
sub backup {
	return if ($keepBackupFiles == 0);
	
	# get the highest backup number
	my $command = "find .para/backup/ -name \".para.jobs.$jobListName.backup*\" | awk -F\"backup\" '{print \$3}' | sort -g | tail -n 1";
	print "backup function: running $command\n" if ($verbose);
	
	my $endNumber = 1;
	$endNumber = `$command`;
	chomp($endNumber);
	$endNumber++;
	print "backup function: new endNumber is $endNumber for $paraJobsFilebackup*\n" if ($verbose);

	system("cp $paraStatusFile $paraStatusFilebackup$endNumber"); 
	system("cp $paraJobsFile $paraJobsFilebackup$endNumber");
	system("cp $paraBsubParaFile $paraBsubParaFilebackup$endNumber");

}

#########################################################################################################
# compute sum of vector
#########################################################################################################
sub getSum {
	my @vector = @_;
	if ($#vector < 0) {
		print STDERR "ERROR: empty vector for getSum\n";
		return -10000000000;
	}

	my $sum = 0;
	my $count = 0;	
	for (my $i=0; $i<=$#vector; $i++) {
		$sum += $vector[$i];
		$count++;
	}
	return $sum;
}

