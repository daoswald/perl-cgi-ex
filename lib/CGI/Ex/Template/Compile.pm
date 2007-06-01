package CGI::Ex::Template::Compile;

=head1 NAME

CGI::Ex::Template::Compile - Transform CET AST to Perl

=head1 DESCRIPTION

=head1 AUTHOR

Paul Seamons <paul at seamons dot com>

=head1 LICENSE

This module may be distributed under the same terms as Perl itself.

=cut

use strict;
use warnings;
use CGI::Ex::Dump qw(debug);

our $VERSION = '2.13';
our $INDENT  = ' ' x 4;
our $PERL_COMPILE_EXT = '.pl';

###----------------------------------------------------------------###

sub load_perl {
    my ($self, $doc) = @_;

    ### first look for a compiled perl document
    my $perl;
    if ($doc->{'_filename'}) {
        $doc->{'modtime'} ||= (stat $doc->{'_filename'})[9];
        if ($self->{'COMPILE_DIR'} || $self->{'COMPILE_EXT'}) {
            my $file = $doc->{'_filename'};
            $file = $doc->{'COMPILE_DIR'} .'/'. $file if $doc->{'COMPILE_DIR'};
            $file .= $self->{'COMPILE_EXT'} if defined($self->{'COMPILE_EXT'});
            $file .= $PERL_COMPILE_EXT      if defined $PERL_COMPILE_EXT;

            if (-e $file && ($doc->{'_is_str_ref'} || (stat $file)[9] == $doc->{'modtime'})) {
                $perl = $self->slurp($file);
            } else {
                $doc->{'_compile_filename'} = $file;
            }
        }
    }

    $perl ||= $self->compile_template($doc);

    ### save a cache on the fileside as asked
    if ($doc->{'_compile_filename'}) {
        my $dir = $doc->{'_compile_filename'};
        $dir =~ s|/[^/]+$||;
        if (! -d $dir) {
            require File::Path;
            File::Path::mkpath($dir);
        }
        open(my $fh, ">", $doc->{'_compile_filename'}) || $self->throw('compile', "Could not open file \"$doc->{'_compile_filename'}\" for writing: $!");
        ### todo - think about locking
        print $fh $$perl;
        close $fh;
        utime $doc->{'modtime'}, $doc->{'modtime'}, $doc->{'_compile_filename'};
    }

    $perl = eval $$perl;
    $self->throw('compile', "Trouble loading compiled perl: $@") if ! $perl && $@;

    return $perl;
}

sub compile_template {
    my ($self, $doc) = @_;

    local $self->{'_component'} = $doc;
    my $tree = $doc->{'_tree'} ||= $self->load_tree($doc);

    local $self->{'_blocks'} = '';
    local $self->{'_meta'}   = '';

    my $code = compile_tree($self, $tree, $INDENT);
    $self->{'_blocks'} .= "\n" if $self->{'_blocks'};
    $self->{'_meta'}   .= "\n" if $self->{'_meta'};

    my $str = "# Generated by ".__PACKAGE__." v$VERSION on ".localtime()."
# From file ".($doc->{'_filename'} || $doc->{'name'})."

my \$blocks = {$self->{'_blocks'}};
my \$meta   = {$self->{'_meta'}};
my \$code   = sub {
${INDENT}my (\$self, \$out_ref, \$var) = \@_;"
.($self->{'_blocks'} ? "\n${INDENT}\@{ \$self->{'BLOCKS'} }{ keys %\$blocks } = values %\$blocks;" : "")
.($self->{'_meta'}   ? "\n${INDENT}\@{ \$self->{'_template'} }{ keys %\$meta } = values %\$meta;" : "")
."$code

${INDENT}return 1;
};

{
${INDENT}blocks => \$blocks,
${INDENT}meta   => \$meta,
${INDENT}code   => \$code,
};\n";
#    print $str;
    return \$str;
}

###----------------------------------------------------------------###

sub _node_info {
    my ($self, $node, $indent) = @_;
    my $doc = $self->{'_component'} || return '';
    $doc->{'_content'} ||= $self->slurp($doc->{'_filename'});
    my ($line, $char) = $self->get_line_number_by_index($doc, $node->[1], 'include_chars');
    return "\n\n${indent}# \"$node->[0]\" Line $line char $char (chars $node->[1] to $node->[2])";
}

sub compile_tree {
    my ($self, $tree, $indent) = @_;
    my $code = '';
    # node contains (0: DIRECTIVE,
    #                1: start_index,
    #                2: end_index,
    #                3: parsed tag details,
    #                4: sub tree for block types
    #                5: continuation sub trees for sub continuation block types (elsif, else, etc)
    #                6: flag to capture next directive
    my @doc;
    for my $node (@$tree) {

        # text nodes are just the bare text
        if (! ref $node) {
            $node =~ s/\\/\\\\/g;
            $node =~ s/\'/\\\'/g;
            $code .= "\n\n${indent}\$\$out_ref .= '$node';";
            next;
        }

        if ($self->{'_debug_dirs'} && ! $self->{'_debug_off'}) {
            my $info = $self->node_info($node);
            my ($file, $line, $text) = @{ $info }{qw(file line text)};
            s/\'/\\\'/g foreach $file, $line, $text;
            $code .= "\n
${indent}if (\$self->{'_debug_dirs'} && ! \$self->{'_debug_off'}) { # DEBUG
${indent}${INDENT}my \$info = {file => '$file', line => '$line', text => '$text'};
${indent}${INDENT}my \$format = \$self->{'_debug_format'} || \$self->{'DEBUG_FORMAT'} || \"\\n## \\\$file line \\\$line : [% \\\$text %] ##\\n\";
${indent}${INDENT}\$format =~ s{\\\$(file|line|text)}{\$info->{\$1}}g;
${indent}${INDENT}\$\$out_ref .= \$format;
${indent}}";
        }

        $code .= _node_info($self, $node, $indent);

        # get method to call
        my $directive = $node->[0];
        $directive = 'FILTER' if $directive eq '|';
        next if $directive eq '#';

        my $method = "compile_$directive";
        __PACKAGE__->$method($self, $node, \$code, $indent);
    }
    return $code;
}

### takes variables or expressions and translates them
### into the language that compiled TT templates understand
### it will recurse as deep as the expression is deep
### foo                      : 'foo'
### ['foo', 0]               : $stash->get('foo')
### ['foo', 0] = ['bar', 0]  : $stash->set('foo', $stash->get('bar'))
### [[undef, '+', 1, 2], 0]  : do { no warnings; 1 + 2 }
sub compile_expr {
    my ($self, $var, $str_ref, $indent) = @_;

    ### return literals
    if (! ref $var) {
        if (! defined $var) {
            $$str_ref .= 'undef';
        } elsif ($var =~ /^-?[1-9]\d{0,13}\b(?:|\.0|\.\d{0,13}[1-9])$/ && ! $self->{'_no_bare_numbers'}) { # return unquoted numbers if it is simple
            $$str_ref .= $var;
        } else {
            $var =~ s/([\'\\])/\\$1/g;
            $$str_ref .= "'$var'";  # return quoted items - if they are simple
        }
        return;
    }

    ### determine the top level of this particular variable access

    my $i = 0;
    my $name = $var->[$i++];
    my $args = $var->[$i++];
    my $is_set   = delete($self->{'_is_set'});
    my $is_undef = delete($self->{'_is_undef'});
    my $open = '$self->'.($is_set ? 'set_variable' : $is_undef ? 'undefined_get' : 'play_variable').'([';

    if (ref $name) {
        if (! defined $name->[0]) { # operator
            if ($is_set) {
                $$str_ref .= "\$var = 'null op set of complex string'";
                return;
            } elsif ($i >= @$var) {
                compile_operator($self, $name, $str_ref, $indent);
                return;
            }

            $$str_ref .= "\$self->play_variable(";
            compile_operator($self, $name, $str_ref, $indent);
            $$str_ref .= ", [undef";
        } else { # a named variable access (ie via $name.foo)
            ### TODO - there are edge cases when doing SET ${ $foo } = 1 that we "may" want to investigate
            $$str_ref .= $open;
            compile_expr($self, $name, $str_ref, $indent);
        }
    } elsif (defined $name) {
        $$str_ref .= $open;
        if ($self->{'is_namespace_during_compile'}) {
            die;
            #$ref = $self->{'NAMESPACE'}->{$name};
        } else {
            $name =~ s/\'/\\\'/g;
            $$str_ref .= "'$name'";
        }
    } else {
        die "Parsed tree error - found an anomaly" if $is_set;
        $$str_ref .= "''"; # not sure we can get here
    }

    ### add args
    if (! $args) {
        $$str_ref .= ', 0';
    } else {
        $$str_ref .= ', [';
        for (0 .. $#$args) {
            compile_expr($self, $args->[$_], $str_ref, $indent);
            $$str_ref .= ', ' if $_ != $#$args;
        }
        $$str_ref .= ']';
    }

    ### now decent through the other levels
    while ($i < @$var) {
        ### descend one chained level
        $$str_ref .= ", '$var->[$i]'";
        my $was_dot_call = $var->[$i++] eq '.';
        $name            = $var->[$i++];
        $args            = $var->[$i++];

        if (ref $name) {
            if (! defined $name->[0]) { # operator
                die;
                #push @ident, '('. $self->compile_operator($name) .')';
            } else { # a named variable access (ie via $name.foo)
                $$str_ref .= ', ';
                compile_expr($self, $name, $str_ref, $indent);
            }
        } elsif (defined $name) {
            if ($self->{'is_namespace_during_compile'}) {
                die;
                #$ref = $self->{'NAMESPACE'}->{$name};
            } else {
                $name =~ s/\'/\\\'/g;
                $$str_ref .= ", '$name'";
            }
        } else {
            $$str_ref .= "''";
        }

        ### add args
        if (! $args) {
            $$str_ref .= ', 0';
        } else {
            $$str_ref .= ', [';
            for (0 .. $#$args) {
                compile_expr($self, $args->[$_], $str_ref, $indent);
                $$str_ref .= ', ' if $_ != $#$args;
            }
            $$str_ref .= ']';
        }
    }

    $$str_ref .= $is_set ? '], $var)' : '])';
}

### same as compile_expr - but without play_variable escaping - this is essentially a Dumper
sub compile_expr_flat {
    my ($self, $var) = @_;

    if (! ref $var) {
        return 'undef' if ! defined $var;
        return $var if $var =~ /^(-?[1-9]\d{0,13}|0)$/;
        $var =~ s/([\'\\])/\\$1/g;
        return "'$var'";
    }

    return '['.join(', ', map { compile_expr_flat($self, $_) } @$var).']';
}


### plays operators
### [[undef, '+', 1, 2], 0]  : do { no warnings; 1 + 2 }
sub compile_operator {
    my ($self, $args, $str_ref, $indent) = @_;
    my (undef, $op, @the_rest) = @$args;
    $op = lc $op;

    $op = ($op eq 'mod') ? '%'
        : ($op eq 'pow') ? '**'
        :                  $op;

    if ($op eq '{}') {
        if (! @the_rest) {
            $$str_ref .= '{}';
            return;
        }
        $$str_ref .= "{\n";
        while (@the_rest) {
            $$str_ref .= "$indent$INDENT";
            compile_expr($self, shift(@the_rest), $str_ref, $indent);
            $$str_ref .= " => ";
            if (@the_rest) {
                compile_expr($self, shift(@the_rest), $str_ref, $indent);
            } else {
                $$str_ref .= "undef";
            }
            $$str_ref .= ",\n";
        }
        $$str_ref .= "}";
        return;
    } elsif ($op eq '[]') {
        $$str_ref .=  "[";
        foreach (0 .. $#the_rest) {
            compile_expr($self, $the_rest[$_], $str_ref, $indent);
            $$str_ref .= ", " if $_ != $#the_rest;
        }
        $$str_ref .= "]";
    } elsif ($op eq '~' || $op eq '_') {
        if (@the_rest == 1 && ! ref $the_rest[0]) {
            if (defined $the_rest[0]) {
                compile_expr($self, $the_rest[0], $str_ref, $indent);
            } else {
                $$str_ref .= "''";
            }
            return;
        }
        $$str_ref .=  "do { no warnings; ''";
        foreach (@the_rest) {
            $$str_ref .= ' . ';
            compile_expr($self, $_, $str_ref, $indent);
        }
        $$str_ref .= ' }';
    } elsif ($op eq '=') {
        $$str_ref .= "do {
${indent}${INDENT}my \$var = ";
        compile_expr($self, $the_rest[1], $str_ref, "$indent$INDENT");
        $$str_ref .= ";
${indent}${INDENT}";
        local $self->{'_is_set'} = 1;
        compile_expr($self, $the_rest[0], $str_ref, "$indent$INDENT");
        $$str_ref .= ";
${indent}${INDENT}\$var
${indent}}";

    # handle assignment operators
    } elsif ($CGI::Ex::Template::OP_ASSIGN->{$op}) {
        $op =~ /^([^\w\s\$]+)=$/ || die "Not sure how to handle that op $op";
        my $short = $1;
        $$str_ref .= "do {
${indent}${INDENT}my \$var = ";
        compile_expr($self, [[undef, $short, $the_rest[0], $the_rest[1]], 0], $str_ref, $indent);
        $$str_ref .= ";
${indent}${INDENT}";
        local $self->{'_is_set'} = 1;
        compile_expr($self, $the_rest[0], $str_ref, $indent);
        $$str_ref .= ";
${indent}${INDENT}\$var;
${indent}}";

    } elsif ($op eq '++') {
        my $is_postfix = $the_rest[1] || 0; # set to 1 during postfix
        $$str_ref .= "do {
${indent}${INDENT}my \$var = ";
        compile_expr($self, [[undef, '+', $the_rest[0], 1], 0], $str_ref, $indent);
        $$str_ref .= ";
${indent}${INDENT}";
        local $self->{'_is_set'} = 1;
        compile_expr($self, $the_rest[0], $str_ref, $indent);
        $$str_ref .= ";
${indent}${INDENT}$is_postfix ? \$var - 1 : \$var;
${indent}}";

    } elsif ($op eq '--') {
        my $is_postfix = $the_rest[1] || 0; # set to 1 during postfix
        $$str_ref .= "do {
${indent}${INDENT}my \$var = ";
        compile_expr($self, [[undef, '-', $the_rest[0], 1], 0], $str_ref, $indent);
        $$str_ref .= ";
${indent}${INDENT}";
        local $self->{'_is_set'} = 1;
        compile_expr($self, $the_rest[0], $str_ref, $indent);
        $$str_ref .= ";
${indent}${INDENT}$is_postfix ? \$var + 1 : \$var;
${indent}}";

    } elsif ($op eq 'div' || $op eq 'DIV') {
        $$str_ref .= 'do { no warnings; int(';
        compile_expr($self, $the_rest[0], $str_ref, $indent);
        $$str_ref .= ' / ';
        compile_expr($self, $the_rest[1], $str_ref, $indent);
        $$str_ref .= ') }';

    } elsif ($op eq '?') {
        $$str_ref .= '(';
        compile_expr($self, $the_rest[0], $str_ref, $indent);
        $$str_ref .= ' ? ';
        compile_expr($self, $the_rest[1], $str_ref, $indent);
        $$str_ref .= ' : ';
        compile_expr($self, $the_rest[2], $str_ref, $indent);
        $$str_ref .= ')';

    } elsif ($op eq '\\') {
        $$str_ref .= "do { my \$var = \$self->play_operator([undef, '\\\\', ";
        $$str_ref .= compile_expr_flat($self, $the_rest[0]);
        $$str_ref .= "]); \$var = \$var->() if UNIVERSAL::isa(\$var, 'CODE'); \$var }";
    } elsif ($op eq 'qr') {
        $$str_ref .= $the_rest[1] ? "qr{(?$the_rest[1]:$the_rest[0])}" : "qr{$the_rest[0]}";

    } elsif (@the_rest == 1) {
        $$str_ref .= "do { no warnings; $op";
        compile_expr($self, $the_rest[0], $str_ref, $indent);
        $$str_ref .= ' }';
    } elsif ($op eq '||' || $op eq '&&') {
        $$str_ref .= '(';
        compile_expr($self, $the_rest[0], $str_ref, $indent);
        $$str_ref .= " $op ";
        compile_expr($self, $the_rest[1], $str_ref, $indent);
        $$str_ref .= ')';
    } else {
        local $self->{'_no_bare_numbers'} = 1; # allow for == vs eq distinction on strings
        $$str_ref .= 'do { no warnings; ';
        compile_expr($self, $the_rest[0], $str_ref, $indent);
        $$str_ref .= " $op ";
        compile_expr($self, $the_rest[1], $str_ref, $indent);
        $$str_ref .= ' }';
    }
}

sub compile_play_named_args {
    my ($self, $node, $str_ref, $indent) = @_;
    my $directive = $node->[0];
    die "Invalid node name \"$directive\"" if $directive !~ /^\w+$/;

    $$str_ref .= "
${indent}\$var = ".compile_expr_flat($self, $node->[3]).";
${indent}\$self->play_$directive(\$var, ['$node->[0]', $node->[1], $node->[2]], \$out_ref);";

    return;
}

sub _is_empty_named_args {
    my ($hash_ident) = @_;
    # [[undef, '{}', 'key1', 'val1', 'key2, 'val2'], 0]
    return @{ $hash_ident->[0] } <= 2;
}

###----------------------------------------------------------------###

sub compile_BLOCK {
    my ($class, $self, $node, $str_ref, $indent) = @_;

    my $ref  = \ $self->{'_blocks'};
    my $name = $node->[3];
    $name =~ s/\'/\\\'/g;
    my $name2 = $self->{'_component'}->{'name'} .'/'. $node->[3];
    $name2 =~ s/\'/\\\'/g;

    my $code = compile_tree($self, $node->[4], "$INDENT$INDENT$INDENT");

    $$ref .= "
${INDENT}'$name' => {
${INDENT}${INDENT}name  => '$name2',
${INDENT}${INDENT}_perl => {code => sub {
${INDENT}${INDENT}${INDENT}my (\$self, \$out_ref, \$var) = \@_;$code

${INDENT}${INDENT}${INDENT}return 1;
${INDENT}${INDENT}}},
${INDENT}},";

    return;
}

sub compile_BREAK { shift->compile_LAST(@_) }

sub compile_CALL {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    $$str_ref .= "\n${indent}scalar ";
    compile_expr($self, $node->[3], $str_ref, $indent);
    $$str_ref .= ";";
    return;
}

sub compile_CLEAR {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    $$str_ref .= "
${indent}\$\$out_ref = '';";
}

sub compile_CONFIG {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    compile_play_named_args($self, $node, $str_ref, $indent);
}

sub compile_DEBUG {
    my ($class, $self, $node, $str_ref, $indent) = @_;

    my $text = $node->[3]->[0];

    if ($text eq 'on') {
        $$str_ref .= "\n${indent}delete \$self->{'_debug_off'};";
    } elsif ($text eq 'off') {
        $$str_ref .= "\n${indent}\$self->{'_debug_off'} = 1;";
    } elsif ($text eq 'format') {
        my $format = $node->[3]->[1];
        $format =~ s/\'/\\\'/g;
        $$str_ref .= "\n${indent}\$self->{'_debug_format'} = '$format';";
    }
    return;
}

sub compile_DEFAULT {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    local $self->{'_is_default'} = 1;
    $class->compile_SET($self, $node, $str_ref, $indent);
}

sub compile_DUMP {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    compile_play_named_args($self, $node, $str_ref, $indent);
}

sub compile_GET {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    $$str_ref .= "\n$indent\$var = ";
    compile_expr($self, $node->[3], $str_ref, $indent);
    $$str_ref .= ";\n$indent\$\$out_ref .= defined(\$var) ? \$var : \$self->undefined_get([";
    local $self->{'_is_undef'} = 1;
    compile_expr($self, $node->[3], $str_ref, $indent);
    $$str_ref .= "]);";
    return;
}

sub compile_END {}

sub compile_FILTER {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    my ($name, $filter) = @{ $node->[3] };
    return if ! @$filter;

    my $_filter = compile_expr_flat($self, $filter);
    $_filter =~ s/^\[//;
    $_filter =~ s/\]$//;
    if (ref $filter->[0]) {
        if (@$filter == 2) { # [% n FILTER $foo %]
            $_filter =~ s/,\s*0$//;
            $_filter = "\$self->play_expr($_filter)";
        } else {
            $_filter = "'', 0"; # if the filter name is too complex - install null filter
        }
    }

    ### allow for alias
    if (length $name) {
        $name =~ s/\'/\\\'/g;
        $$str_ref .= "\n$indent\$self->{'FILTERS'}->{'$name'} = [$_filter]; # alias for future calls\n";
    }

    my $code = compile_tree($self, $node->[4], "$indent$INDENT");


    $$str_ref .= "
${indent}\$var = do {
${indent}${INDENT}my \$out = '';
${indent}${INDENT}my \$out_ref = \\\$out;
$code

${indent}${INDENT}\$out;
${indent}};
${indent}\$var = \$self->play_variable(\$var, [undef, 0, '|', $_filter]);
${indent}\$\$out_ref .= \$var if defined \$var;";

}

sub compile_FOR {
    my ($class, $self, $node, $str_ref, $indent) = @_;

    my ($name, $items) = @{ $node->[3] };
    local $self->{'_in_loop'} = 'FOREACH';
    my $code = compile_tree($self, $node->[4], "$indent$INDENT");

    $$str_ref .= "\n${indent}do {
${indent}my \$loop = ";
    compile_expr($self, $items, $str_ref, $indent);
    $$str_ref .= ";
${indent}\$loop = [] if ! defined \$loop;
${indent}\$loop = \$self->iterator(\$loop) if ref(\$loop) !~ /Iterator\$/;
${indent}local \$self->{'_vars'}->{'loop'} = \$loop;";
    if (! defined $name) {
        $$str_ref .= "
${indent}my \$swap = \$self->{'_vars'};
${indent}local \$self->{'_vars'} = my \$copy = {%\$swap};";
    }

    $$str_ref .= "
${indent}my (\$var, \$error) = \$loop->get_first;
${indent}FOREACH: while (! \$error) {";

    if (defined $name) {
        $$str_ref .= "\n$indent$INDENT";
        local $self->{'_is_set'} = 1;
        compile_expr($self, $name, $str_ref, $indent);
        $$str_ref .= ";";
    } else {
        $$str_ref .= "\n$indent$INDENT\@\$copy{keys %\$var} = values %\$var if ref(\$var) eq 'HASH';";
    }

    $$str_ref .= "$code
${indent}${INDENT}(\$var, \$error) = \$loop->get_next;
${indent}}
${indent}};";
    return;
}

sub compile_FOREACH { shift->compile_FOR(@_) }

sub compile_IF {
    my ($class, $self, $node, $str_ref, $indent) = @_;

    $$str_ref .= "\n${indent}if (";
    compile_expr($self, $node->[3], $str_ref, $indent);
    $$str_ref .= ") {";
    $$str_ref .= compile_tree($self, $node->[4], "$indent$INDENT");

    while ($node = $node->[5]) { # ELSE, ELSIF's
        $$str_ref .= _node_info($self, $node, $indent);
        if ($node->[0] eq 'ELSE') {
            $$str_ref .= "\n${indent}} else {";
            $$str_ref .= compile_tree($self, $node->[4], "$indent$INDENT");
            last;
        } else {
            $$str_ref .= "\n${indent}} elsif (";
            compile_expr($self, $node->[3], $str_ref, $indent);
            $$str_ref .= ") {";
            $$str_ref .= compile_tree($self, $node->[4], "$indent$INDENT");
        }
    }
    $$str_ref .= "\n${indent}}";
}

sub compile_INCLUDE { shift->compile_PROCESS(@_) }

sub compile_LAST {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    my $type = $self->{'_in_loop'} || die "Found LAST while not in FOR, FOREACH or WHILE";
    $$str_ref .= "\n${indent}last $type;";
    return;
}

sub compile_LOOP {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    my $ref = $node->[3];
    $ref = [$ref, 0] if ! ref $ref;

    $$str_ref .= "
${indent}\$var = ";
    compile_expr($self, $ref, $str_ref, $indent);

    my $code = compile_tree($self, $node->[4], "$indent$INDENT$INDENT");

    $$str_ref .= ";
${indent}if (\$var) {
${indent}${INDENT}my \$global = ! \$self->{'SYNTAX'} || \$self->{'SYNTAX'} ne 'ht' || \$self->{'GLOBAL_VARS'};
${indent}${INDENT}my \$items  = ref(\$var) eq 'ARRAY' ? \$var : ref(\$var) eq 'HASH' ? [\$var] : [];
${indent}${INDENT}my \$i = 0;
${indent}${INDENT}for my \$ref (\@\$items) {
${indent}${INDENT}${INDENT}\$self->throw('loop', 'Scalar value used in LOOP') if \$ref && ref(\$ref) ne 'HASH';
${indent}${INDENT}${INDENT}local \$self->{'_vars'} = (! \$global) ? (\$ref || {}) : (ref(\$ref) eq 'HASH') ? {%{ \$self->{'_vars'} }, %\$ref} : \$self->{'_vars'};
${indent}${INDENT}${INDENT}\@{ \$self->{'_vars'} }{qw(__counter__ __first__ __last__ __inner__ __odd__)}
${indent}${INDENT}${INDENT}${INDENT}= (++\$i, (\$i == 1 ? 1 : 0), (\$i == \@\$items ? 1 : 0), (\$i == 1 || \$i == \@\$items ? 0 : 1), (\$i % 2) ? 1 : 0)
${indent}${INDENT}${INDENT}${INDENT}${INDENT}if \$self->{'LOOP_CONTEXT_VARS'} && ! \$CGI::Ex::Template::QR_PRIVATE;$code
${indent}${INDENT}}
${indent}}";
}

sub compile_MACRO {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    my ($name, $args) = @{ $node->[3] };

    ### get the sub tree
    my $sub_tree = $node->[4];
    if (! $sub_tree || ! $sub_tree->[0]) {
        $$str_ref .= "
${indent}\$var = undef;
${indent}";
        local $self->{'_is_set'} = 1;
        compile_expr($self, $name, $str_ref, $indent);
        $$str_ref .= ";";
        return;
    } elsif ($sub_tree->[0]->[0] eq 'BLOCK') {
        $sub_tree = $sub_tree->[0]->[4];
    }

    my $code = compile_tree($self, $sub_tree, "$indent$INDENT");

    $$str_ref .= "
${indent}my \$self_copy = \$self;
${indent}eval {require Scalar::Util; Scalar::Util::weaken(\$self_copy)};
${indent}\$var = sub {
${indent}${INDENT}my \$copy = \$self_copy->{'_vars'};
${indent}${INDENT}local \$self_copy->{'_vars'}= {%\$copy};

${indent}${INDENT}local \$self_copy->{'_macro_recurse'} = \$self_copy->{'_macro_recurse'} || 0;
${indent}${INDENT}my \$max = \$self_copy->{'MAX_MACRO_RECURSE'} || \$CGI::Ex::Template::MAX_MACRO_RECURSE;
${indent}${INDENT}\$self_copy->throw('macro_recurse', \"MAX_MACRO_RECURSE \$max reached\")
${indent}${INDENT}${INDENT}if ++\$self_copy->{'_macro_recurse'} > \$max;
";

    foreach my $var (@$args) {
        $$str_ref .= "
${indent}${INDENT}\$self_copy->set_variable(";
        $$str_ref .= compile_expr_flat($self, $var);
        $$str_ref .= ", shift(\@_));";
    }
    $$str_ref .= "
${indent}${INDENT}if (\@_ && \$_[-1] && UNIVERSAL::isa(\$_[-1],'HASH')) {
${indent}${INDENT}${INDENT}my \$named = pop \@_;
${indent}${INDENT}${INDENT}foreach my \$name (sort keys %\$named) {
${indent}${INDENT}${INDENT}${INDENT}\$self_copy->set_variable([\$name, 0], \$named->{\$name});
${indent}${INDENT}${INDENT}}
${indent}${INDENT}}

${indent}${INDENT}my \$out = '';
${indent}${INDENT}my \$out_ref = \\\$out;$code
${indent}${INDENT}return \$out;
${indent}};
${indent}";

    local $self->{'_is_set'} = 1;
    compile_expr($self, $name, $str_ref, $indent);
    $$str_ref .= ";";

    return;
}

sub compile_META {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    if ($node->[3]) {
        while (my($key, $val) = each %{ $node->[3] }) {
            s/\'/\\\'/g foreach $key, $val;
            $self->{'_meta'} .= "\n${indent}'$key' => '$val',";
        }
    }
    return;
}

sub compile_NEXT {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    my $type = $self->{'_in_loop'} || die "Found next while not in FOR, FOREACH or WHILE";
    $$str_ref .= "\n${indent}(\$var, \$error) = \$loop->get_next;" if $type eq 'FOREACH';
    $$str_ref .= "\n${indent}next $type;";
    return;
}

sub compile_PERL{
    my ($class, $self, $node, $str_ref, $indent) = @_;

    ### fill in any variables
    my $perl = $node->[4] || return;
    my $code = compile_tree($self, $perl, "$indent$INDENT");

    $$str_ref .= "
${indent}\$self->throw('perl', 'EVAL_PERL not set') if ! \$self->{'EVAL_PERL'};
${indent}require CGI::Ex::Template::Play;
${indent}\$var = do {
${indent}${INDENT}my \$out = '';
${indent}${INDENT}my \$out_ref = \\\$out;$code
${indent}${INDENT}\$out;
${indent}};
${indent}#\$var = \$1 if \$var =~ /^(.+)\$/s; # blatant untaint

${indent}my \$err;
${indent}eval {
${indent}${INDENT}package CGI::Ex::Template::Perl;
${indent}${INDENT}my \$context = \$self->context;
${indent}${INDENT}my \$stash   = \$context->stash;
${indent}${INDENT}local *PERLOUT;
${indent}${INDENT}tie *PERLOUT, 'CGI::Ex::Template::EvalPerlHandle', \$out_ref;
${indent}${INDENT}my \$old_fh = select PERLOUT;
${indent}${INDENT}eval \$var;
${indent}${INDENT}\$err = \$\@;
${indent}${INDENT}select \$old_fh;
${indent}};
${indent}\$err ||= \$\@;
${indent}if (\$err) {
${indent}${INDENT}\$self->throw('undef', \$err) if ref(\$err) !~ /Template::Exception\$/;
${indent}${INDENT}die \$err;
${indent}}";

    return;
}


sub compile_PROCESS {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    compile_play_named_args($self, $node, $str_ref, $indent);
}

sub compile_RETURN {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    $$str_ref .= "
${indent}\$self->throw('return', 'Control Exception');";
}

sub compile_SET {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    my $sets = $node->[3];

    my $out = '';
    foreach (@$sets) {
        my ($op, $set, $val) = @$_;

        $$str_ref .= "\n$indent\$var = ";

        if ($CGI::Ex::Template::OP_DISPATCH->{$op}) {
            $op =~ /^([^\w\s\$]+)=$/ || die "Not sure how to handle that op $op during SET";
            my $short = ($1 eq '_' || $1 eq '~') ? '.' : $1;
            $$str_ref .= 'do { no warnings; ';
            compile_expr($self, $set, $str_ref, $indent);
            $$str_ref .= " $short ";
        }

        if (! defined $val) { # not defined
            $$str_ref .= 'undef';
        } elsif ($node->[4] && $val == $node->[4]) { # a captured directive
            my $sub_tree = $node->[4];
            $sub_tree = $sub_tree->[0]->[4] if $sub_tree->[0] && $sub_tree->[0]->[0] eq 'BLOCK';
            my $code = compile_tree($self, $sub_tree, "$indent$INDENT");
            $$str_ref .= "${indent}do {
${indent}${indent}my \$out = '';
${indent}${indent}my \$out_ref = \\\$out;$code
${indent}${indent}\$out;
${indent}}"
        } else { # normal var
            compile_expr($self, $val, $str_ref, $indent);
        }

        if ($CGI::Ex::Template::OP_DISPATCH->{$op}) {
            $$str_ref .= ' }';
        }
        $$str_ref .= ";\n$indent";

        local $self->{'_is_set'} = 1;
        compile_expr($self, $set, $str_ref, $indent);

        if ($self->{'_is_default'}) {
            delete $self->{'_is_set'};
            $$str_ref .= ' if ! ';
            compile_expr($self, $set, $str_ref, $indent);
        }

        $$str_ref .= ";";
    }

    return $out;
}

sub compile_STOP {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    $$str_ref .= "
${indent}\$self->throw('stop', 'Control Exception');";
}

sub compile_SWITCH {
    my ($class, $self, $node, $str_ref, $indent) = @_;

    $$str_ref .= "
${indent}\$var = ";
    compile_expr($self, $node->[3], $str_ref, $indent);
    $$str_ref .= ";";

    my $default;
    my $i = 0;
    while ($node = $node->[5]) { # CASES
        if (! defined $node->[3]) {
            $default = $node->[4];
            next;
        }

        $$str_ref .= _node_info($self, $node, $indent);
        $$str_ref .= "\n$indent" .($i++ ? "} els" : ""). "if (do {
${indent}${INDENT}no warnings;
${indent}${INDENT}my \$var2 = ";
        compile_expr($self, $node->[3], $str_ref, "$indent$INDENT");
        $$str_ref .= ";
${indent}${INDENT}scalar grep {\$_ eq \$var} (UNIVERSAL::isa(\$var2, 'ARRAY') ? \@\$var2 : \$var2);
${indent}${INDENT}}) {
${indent}${INDENT}my \$var;";

        $$str_ref .= compile_tree($self, $node->[4], "$indent$INDENT");
    }

    if ($default) {
        $$str_ref .= _node_info($self, $node, $indent);
        $$str_ref .= "\n$indent" .($i++ ? "} else {" : "if (1) {");
        $$str_ref .= compile_tree($self, $default, "$indent$INDENT");
    }

    $$str_ref .= "\n$indent}" if $i;

    return;
}

sub compile_TAGS {}

sub compile_THROW {
    my ($class, $self, $node, $str_ref, $indent) = @_;

    my ($name, $args) = @{ $node->[3] };

    my ($named, @args) = @$args;
    push @args, $named if ! _is_empty_named_args($named); # add named args back on at end - if there are some

    $$str_ref .= "
${indent}\$self->throw(";
    compile_expr($self, $name, $str_ref, $indent);
    $$str_ref .= ", [";
    foreach (0 .. $#args) {
        compile_expr($self, $args[$_], $str_ref, $indent);
        $$str_ref .= ", " if $_ != $#args;
    }
    $$str_ref .= "]);";
    return;
}


sub compile_TRY {
    my ($class, $self, $node, $str_ref, $indent) = @_;

    $$str_ref .= "
${indent}do {
${indent}my \$out = '';
${indent}eval {
${indent}${INDENT}my \$out_ref = \\\$out;"
    . compile_tree($self, $node->[4], "$indent$INDENT") ."
${indent}};
${indent}my \$err = \$\@;
${indent}\$\$out_ref .= \$out;
${indent}if (\$err) {";

    my $final;
    my $i = 0;
    my $catches_str = '';
    my @names;
    while ($node = $node->[5]) { # CATCHES
        if ($node->[0] eq 'FINAL') {
            $final = $node->[4];
            next;
        }
        $catches_str .= _node_info($self, $node, "$indent$INDENT");
        $catches_str .= "\n${indent}${INDENT}} elsif (\$index == ".(scalar @names).") {";
        $catches_str .= compile_tree($self, $node->[4], "$indent$INDENT$INDENT");
        push @names, $node->[3];
    }
    if (@names) {
        $$str_ref .= "
${indent}${INDENT}\$err = \$self->exception('undef', \$err) if ref(\$err) !~ /Template::Exception\$/;
${indent}${INDENT}my \$type = \$err->type;
${indent}${INDENT}die \$err if \$type =~ /stop|return/;
${indent}${INDENT}local \$self->{'_vars'}->{'error'} = \$err;
${indent}${INDENT}local \$self->{'_vars'}->{'e'}     = \$err;

${indent}${INDENT}my \$index;
${indent}${INDENT}my \@names = (";
        $i = 0;
        foreach $i (0 .. $#names) {
            if (defined $names[$i]) {
                $$str_ref .= "\n${indent}${INDENT}${INDENT}scalar(";
                compile_expr($self, $names[$i], $str_ref, "$indent$INDENT$INDENT");
                $$str_ref .= "), # $i;";
            } else {
                $$str_ref .= "\n${indent}${INDENT}${INDENT}undef, # $i";
            }
        }
        $$str_ref .= "
${indent}${INDENT});
${indent}${INDENT}for my \$i (0 .. \$#names) {
${indent}${INDENT}${INDENT}my \$name = (! defined(\$names[\$i]) || lc(\$names[\$i]) eq 'default') ? '' : \$names[\$i];
${indent}${INDENT}${INDENT}\$index = \$i if \$type =~ m{^ \\Q\$name\\E \\b}x && (! defined(\$index) || length(\$names[\$index]) < length(\$name));
${indent}${INDENT}}
${indent}${INDENT}if (! defined \$index) {
${indent}${INDENT}${INDENT}die \$err;"
.$catches_str."
${indent}${INDENT}}";

    } else {
        $$str_ref .= "
${indent}\$self->throw('throw', 'Missing CATCH block');";
    }
    $$str_ref .= "
${indent}}";
    if ($final) {
        $$str_ref .= _node_info($self, $node, $indent);
        $$str_ref .= compile_tree($self, $final, "$indent");
    }
    $$str_ref .="
${indent}};";

    return;
}

sub compile_UNLESS { shift->compile_IF(@_) }

sub compile_USE {
    my ($class, $self, $node, $str_ref, $indent) = @_;
    compile_play_named_args($self, $node, $str_ref, $indent);
}

sub compile_WHILE {
    my ($class, $self, $node, $str_ref, $indent) = @_;

    local $self->{'_in_loop'} = 'WHILE';
    my $code = compile_tree($self, $node->[4], "$indent$INDENT");

    $$str_ref .= "
${indent}my \$count = \$CGI::Ex::Template::WHILE_MAX;
${indent}WHILE: while (--\$count > 0) {
${indent}my \$var = ";
    compile_expr($self, $node->[3], $str_ref, $indent);
    $$str_ref .= ";
${indent}last if ! \$var;$code
${indent}}";
    return;
}

###----------------------------------------------------------------###

1;
