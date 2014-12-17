use v6;

my constant DEBUG = 1;

module Terminal::Control {
    our %human-commands;
    our %human-controls;
    our %tput-controls;
    our %attributes;
    our %attribute-values;

    INIT {
        %human-commands = %(
            'clear'              => 'clear',
            'save-screen'        => 'smcup',
            'restore-screen'     => 'rmcup',
            'pos-cursor-save'    => 'sc',
            'pos-cursor-restore' => 'rc',
            'hide-cursor'        => 'civis',
            'show-cursor'        => 'cnorm', 
        );

        for %human-commands.kv -> $human,$command {
            %tput-controls{$command} = qq:x{ tput $command };
            %human-controls{$human} = %tput-controls{$command};
        }

        %attributes = %(
            'columns'       => 'cols',
            'rows'          => 'lines',
            'lines'         => 'lines',
        );

        %attribute-values<columns>  = %*ENV<COLUMNS> //= qq:x{ tput cols };
        %attribute-values<rows>     = %*ENV<ROWS>    //= qq:x{ tput lines };
    }

    our sub cursor_to( Int $x, Int $y ) {
        "\e[{$x};{$y}H"; # we are using the hardcoded ANSI because it's the
                         # least inelegant solution
    }

    our sub tput( Str $command ) {
        die "Not a supported (or perhaps even valid) tput command"
            unless %tput-controls{$command};

        %tput-controls{$command};
    }
}


constant T = ::Terminal::Control;

class Boxbrain::Cell {
    has $.x is rw;
    has $.y is rw;
    has $.char is rw;
    has %.attr is rw;
    has $!print-string;

    # not working as expected ...
    method set( :$x, :$y, :$char ) {
        $!x = $x ?? $x !! $!x;
        $!y = $y ?? $y !! $!y;
        $!char = $char ?? $char !! $char;
    }

    # TODO: throw specific exceptions if any of these vars are undef
    method cell-string {
        $!print-string //= "{T::cursor_to($!y,$!x)}{$!char}";
    }

    method print-cell {
        die self.perl.say unless $!x,$!y,$!char;
        $!print-string //= "{T::cursor_to($!y,$!x)}{$!char}";
        print $!print-string;
    }
}

# make columns a class so that we can do at_pos
class Boxbrain::Column {
    has @.cells is rw;
    has $.column;
    has $!max-rows;

    method new( :$max-rows, :$column ) {
        my @cells; for 0..$max-rows { @cells[$_] = Boxbrain::Cell.new };
        self.bless( :$max-rows, :$column, :@cells );
    }


    method at_pos( $y ) {
        @!cells[$y];
    }
    
    method assign_pos ( $y, Str $char ) {
        @!cells[$y].char = $char;
    }

}

class Boxbrain::Grid {
    has @.grid;
    has @.buffer;

    has $.max-columns;
    has $.max-rows;

    has @.grid-indices;
    has @.column-range;
    has @.row-range;

    method new( :$max-columns, :$max-rows ) {
        my @column-range = (0..^$max-columns).values;
        my @row-range = (0..$max-rows).values;
        my @grid-indices = (@column-range X @row-range).map({ [$^x, $^y] });

        my (@grid, @buffer);
        for @column-range -> $x {
            @grid[ $x ] //= Boxbrain::Column.new( :$max-rows, column => $x );
            for @grid[ $x ].cells.kv -> $y, $cell {
                $cell.x = $x;
                $cell.y = $y;
                $cell.char = '3';  # TODO: self.clear-buffer / move this where it belongs
            }
        }

        for @grid-indices -> [$x,$y] {
            @buffer[$x + ($y * $max-columns)] := @grid[ $x ][ $y ];
        }

        self.bless( :$max-columns, :$max-rows, :@grid-indices,
                    :@column-range, :@row-range, :@grid, :@buffer );
    }

    method at_pos( $column ) {
        @!grid[ $column ];
    }
}


class Boxbrain {
    has $!current-buffer;
    has $!current-grid;

    has @!buffers;
    has @!grids;

    has @.grid-indices;
    has %!grid-map;

    has $.max-columns;
    has $.max-rows;

    method new( *@args ) {
        self.bless(@args);
    }

    submethod BUILD {
        $!max-columns   = +%T::attribute-values<columns>;
        $!max-rows      = +%T::attribute-values<rows>;

        $!current-grid = Boxbrain::Grid.new( :$!max-columns, :$!max-rows );
        @!grid-indices = $!current-grid.grid-indices;

        $!current-buffer := self!bind-buffer( $!current-grid );

        # we will support creating extra buffers
        push @!buffers, $!current-buffer;
        push @!grids, $!current-grid;
    }

    method !bind-buffer( Boxbrain::Grid $grid ) {
        my $new-buffer = [];
        for $grid.grid-indices -> [$x,$y] {
            $new-buffer[$x + ($y * $!max-rows)] := $grid[$x][$y];
        }
        $new-buffer;
    }

    method add-grid( $name? ) {
        my $new-grid    = Boxbrain::Grid.new( :$!max-columns, :$!max-rows );
        my $new-buffer := self!bind-buffer( $new-grid );
        push @!grids, $new-grid;
        push @!buffers, $new-buffer;

        if $name {
            %!grid-map{$name} = ^@!grids;
        }
    }

    multi method grid( Int $index ) {
        @!grids[$index].grid;
    }

    multi method grid( Str $name ) {
        die "No grid has been named $name" unless my $grid-index = %!grid-map{$name};
        @!grids[$grid-index].grid;
    }

    multi method buffer( Int $index ) {
        @!buffers[$index].buffer;
    }

    multi method buffer( Str $name ) {
        die "No buffer has been named $name" unless my $buffer-index = %!grid-map{$name};
        @!buffers[$buffer-index].buffer;
    }

    method blit( $grid-identifier = 0 ) {
        say [~] .buffer( $grid-identifier ).map: { .char };

#        $grid-identifier ?? do say [~] .buffer( $grid-identifier ).map: { .char }
#                         !! do say [~] $!current-buffer.map: { .char } ;
    }

    method at_pos( $column ) {
        $!current-grid.grid[ $column ];
    }

    method postcircumfix:<( )> ($t) {
        die "Can only specify x, y, and char" if @$t > 3;
        my ($x,$y,$char) = @$t;
        given +@$t {
            when 3 { $!current-grid[ $x ][ $y ] = $char }
            when 2 { $!current-grid[ $x ][ $y ] }
            when 1 { $!current-grid[ $x ] }
        }
    }

# TODO: multiple buffers and grids
#    method clear-grid {
#        for @!current-grid[ $x ].cells -> $c { $c.set( :$x, :char(' ') ) };
#    }

    # 'clear' will also work through the FALLBACK
    method clear-screen {
        print %T::human-controls<clear>;
    }

    method initialize-screen {
        print %T::human-controls<save-screen>;
        self.hide-cursor;
        self.clear-screen;
    }

    method shutdown-screen {
        print %T::human-controls<restore-screen>;
        self.show-cursor;
    }

    multi method FALLBACK( Str $command-name ) {
        die "Do not know command $command-name" unless %T::human-controls{$command-name};
        print %T::human-controls{$command-name};
    }

}

#$b.blit;
##$b.blit("Z");
##$b.blit("!");
#
##$b(3,4).perl.say;
##$b(3,).perl.say;
#
#$b(6,30).char = '$';

#    $b(7,30,'*');
#
#$b[6][31] = "%";
#
#$b.blit;
#
#sleep 2;


#$b.grid-indices.perl.say;

use Term::ANSIColor;
my @colors = <red magenta yellow white>;

my $b = Boxbrain.new;

$b.initialize-screen;

my @hearts;
for $b.grid-indices -> [$x,$y] {
    next if $x ~~ 0;
    if $x %% 3 and $y+1 %% 3 {
        $b[$x][$y] = colored('♥', @colors.roll);
        push @hearts, [$x,$y];
    }
}

$b.add-grid;

for $b.grid-indices -> [$x,$y] {
    next if $x ~~ 0 or $y ~~ $b.max-rows;
    if $x %% 3 and $y+1 %% 3 {
        $b.grid(0)[$x-1][$y+1] = colored('5', @colors.roll);
        push @hearts, [$x,$y];
    }
}

for @hearts.pick( +@hearts ) -> [$x,$y] {
    $b[$x][$y].print-cell;
#    sleep 0.005;
}

$b.blit(1);
sleep 1.5;
$b.blit;
sleep 1.5;
$b.blit(1);
sleep 1.5;
$b.blit;
sleep 1.5;


#sleep 4;

$b.shutdown-screen;



