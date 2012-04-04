package Sys::Cmd;
use strict;
use warnings;
use 5.006;
use Moo;
use Carp qw/carp confess croak/;
use Cwd qw/cwd/;
use IO::Handle;
use File::chdir;
use File::Which qw/which/;
use Log::Any qw/$log/;
use File::Spec::Functions qw/splitdir/;
use POSIX ":sys_wait_h";
use Sub::Exporter -setup => { exports => [qw/spawn run runx/], };

our $VERSION = '0.07_2';
our $CONFESS;

sub run {
    my $proc = spawn(@_);
    my @out  = $proc->stdout->getlines;
    my @err  = $proc->stderr->getlines;

    $proc->wait_child;

    if ( $proc->exit != 0 ) {
        confess( join( '', @err ) . 'Command exited with value ' . $proc->exit )
          if $CONFESS;
        croak( join( '', @err ) . 'Command exited with value ' . $proc->exit );
    }

    if (wantarray) {
        return @out;
    }
    else {
        return join( '', @out );
    }
}

sub runx {
    my $proc = spawn(@_);
    my @out  = $proc->stdout->getlines;
    my @err  = $proc->stderr->getlines;

    $proc->wait_child;

    if ( $proc->exit != 0 ) {
        confess( join( '', @err ) . 'Command exited with value ' . $proc->exit )
          if $CONFESS;
        croak( join( '', @err ) . 'Command exited with value ' . $proc->exit );
    }

    if (wantarray) {
        return @out, @err;
    }
    else {
        return join( '', @out, @err );
    }
}

sub spawn {
    my @cmd = grep { ref $_ ne 'HASH' } @_;

    defined $cmd[0] || confess '$cmd must be defined';

    if ( !-f $cmd[0] ) {
        $cmd[0] = which( $cmd[0] ) || confess 'command not found: ' . $cmd[0];
    }

    my @opts = grep { ref $_ eq 'HASH' } @_;
    if ( @opts > 2 ) {
        confess __PACKAGE__ . ": only a single hashref allowed";
    }

    my %args = @opts ? %{ $opts[0] } : ();
    $args{cmd} = \@cmd;

    return Sys::Cmd->new(%args);
}

has 'cmd' => (
    is  => 'ro',
    isa => sub {
        ref $_[0] eq 'ARRAY' || confess "cmd must be ARRAYREF";
        @{ $_[0] } || confess "Missing cmd elements";
        if ( grep { !defined $_ } @{ $_[0] } ) {
            confess 'cmd array cannot contain undef elements';
        }
    },
    required => 1,
);

has 'encoding' => (
    is      => 'ro',
    default => sub { 'utf8' },
);

has 'env' => (
    is        => 'ro',
    isa       => sub { ref $_[0] eq 'HASH' || confess "env must be HASHREF" },
    predicate => 'have_env',
);

has 'dir' => (
    is      => 'ro',
    default => sub { cwd },
);

has 'input' => (
    is        => 'ro',
    predicate => 'have_input',
);

has 'pid' => (
    is       => 'rw',
    init_arg => undef,
);

has 'stdin' => (
    is       => 'rw',
    init_arg => undef,
);

has 'stdout' => (
    is       => 'rw',
    init_arg => undef,
);

has 'stderr' => (
    is       => 'rw',
    init_arg => undef,
);

has _on_exit => (
    is       => 'rw',
    init_arg => 'on_exit',
);

has 'exit' => (
    is        => 'rw',
    init_arg  => undef,
    predicate => 'have_exit',
);

has 'signal' => (
    is       => 'rw',
    init_arg => undef,
);

has 'core' => (
    is       => 'rw',
    init_arg => undef,
);

my @children;

sub BUILD {
    my $self = shift;
    local $CWD = $self->dir;

    my $r_in  = IO::Handle->new;
    my $r_out = IO::Handle->new;
    my $r_err = IO::Handle->new;
    my $w_in  = IO::Handle->new;
    my $w_out = IO::Handle->new;
    my $w_err = IO::Handle->new;

    $w_in->autoflush(1);
    $w_out->autoflush(1);
    $w_err->autoflush(1);

    pipe( $r_in,  $w_in )  || die "pipe: $!";
    pipe( $r_out, $w_out ) || die "pipe: $!";
    pipe( $r_err, $w_err ) || die "pipe: $!";

    push( @children, $self );
    $SIG{CHLD} ||= \&_reap if $self->_on_exit;

    # spawn the command
    $log->debug( scalar $self->cmdline );

    $self->pid( fork() );
    if ( !defined $self->pid ) {
        my $why = $!;
        pop @children;
        die "fork: $why";
    }

    if ( $self->pid == 0 ) {    # Child
        $SIG{CHLD} = 'DEFAULT';
        if ( !open STDERR, '>&=', fileno($w_err) ) {
            print $w_err "open: $! at ", caller, "\n";
            die "open: $!";
        }
        open STDIN,  '<&=', fileno($r_in)  || die "open: $!";
        open STDOUT, '>&=', fileno($w_out) || die "open: $!";

        close $r_out;
        close $r_err;
        close $r_in;
        close $w_in;
        close $w_out;
        close $w_err;

        if ( $self->have_env ) {
            while ( my ( $key, $val ) = each %{ $self->env } ) {
                if ( defined $val ) {
                    $ENV{$key} = $val;
                }
                else {
                    delete $ENV{$key};
                }
            }
        }

        exec( $self->cmdline );
    }

    # Parent continues from here
    close $r_in;
    close $w_out;
    close $w_err;

    my $enc = ':encoding(' . $self->encoding . ')';

    binmode $w_in,  $enc;
    binmode $r_out, $enc;
    binmode $r_err, $enc;

    # some input was provided
    if ( $self->have_input ) {
        local $SIG{PIPE} =
          sub { warn "Broken pipe when writing to:" . $self->cmdline };

        print {$w_in} $self->input if length $self->input;

        $w_in->close;
    }

    $self->stdin($w_in);
    $self->stdout($r_out);
    $self->stderr($r_err);
    return;
}

sub cmdline {
    my $self = shift;
    if (wantarray) {
        return @{ $self->cmd };
    }
    else {
        return join( ' ', @{ $self->cmd } );
    }
}

# A signal handler, not a method
sub _reap {
    my $sig = shift;
    my $try = shift || '';

    croak '_reap("CHLD",[$pid])' unless $sig eq 'CHLD';

    while (1) {
        my $pid;
        local $?;
        local $!;

        if ($try) {
            $pid = waitpid $try, 0;
            $try = undef;
        }
        else {
            $pid = waitpid -1, &WNOHANG;
        }

        my $ret = $?;

        if ( $pid == -1 ) {

            # No child processes running
            last;
        }
        elsif ( $pid == 0 ) {

            # child processes still running, but not ours??
            last;
        }

        if ( $ret == -1 ) {

            # So waitpid returned a PID but then sets $? to this
            # strange value? (Strange in that tests randomly show it to
            # be invalid.) Most likely a perl bug; I think that waitpid
            # got interrupted and when it restarts/resumes the status
            # is lost.
            #
            # See http://www.perlmonks.org/?node_id=641620 for a
            # possibly related discussion.
            #
            # However, since I localised $? and $! above I haven't seen
            # this problem again, so I hope that is a good enough work
            # around. Lets warn any way so that we know when something
            # dodgy is going on.
            warn __PACKAGE__
              . ' received invalid child exit status for pid '
              . $pid
              . ' Setting to 0';
            $ret = 0;

        }

        my @dead = grep { $_->pid == $pid } @children;
        @children = grep { $_->pid != $pid } @children;

        if ( !@dead ) {
            warn __PACKAGE__
              . ' not our child: '
              . $pid
              . ' exit '
              . ( $ret >> 8 )
              . ' signal '
              . ( $ret & 127 )
              . ' core '
              . ( $ret & 128 );
            next;
        }

        foreach my $child (@dead) {
            $child->exit( $ret >> 8 );
            $child->signal( $ret & 127 );
            $child->core( $ret & 128 );
            if ( my $subref = $child->_on_exit ) {
                $subref->($child);
            }
        }
    }

    return;
}

sub wait_child {
    my $self = shift;

    _reap( 'CHLD', $self->pid ) unless $self->have_exit;
    return;
}

sub close {
    my $self = shift;

    my $in  = $self->stdin || return;
    my $out = $self->stdout;
    my $err = $self->stderr;

    $in->opened  and $in->close  || carp "error closing stdin: $!";
    $out->opened and $out->close || carp "error closing stdout: $!";
    $err->opened and $err->close || carp "error closing stderr: $!";

    $self->stdin(undef);
    $self->stdout(undef);
    $self->stderr(undef);

    return;
}

sub DESTROY {
    my $self = shift;

    $self->close;
    _reap( 'CHLD', $self->pid ) unless $self->have_exit;
    return;
}

1;

