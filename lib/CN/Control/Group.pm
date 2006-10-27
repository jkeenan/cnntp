package CN::Control::Group;
use strict;
use base qw(CN::Control);
use Apache::Constants qw(OK);
use CN::Model;
use POSIX qw(ceil);

sub request_setup {
    my $self = shift;
    
    return $self->{setup} if $self->{setup};

    my ($group_name, $year, $month, $page_type, $number) = 
      ($self->request->uri =~ m!^/group(?:/([^/]+)
                                        (?:/([^/]+))?
                                        (?:/([^/]+))?
                                        (?:/(msg|page)(\d+))?
                                       .html)?!x);

    my ($page, $article) = (0, 0);
    if ($page_type and defined $number) {
        $page    = $number if $page_type eq 'page';
        $article = $number if $page_type eq 'msg';
    }

    unless ($group_name) {
        ($group_name, $article) = 
            ($self->request->uri =~ m!^/group(?:/([^/]+)
                                              (?:/(\d+))?
                                              )?!x);
    }
    
    return $self->{setup} = { group_name => $group_name || '',
                              year       => $year || 0,
                              month      => $month || 0,
                              article    => $article,
                              page       => $page || 1,
                            };
}

sub render {
    my $self = shift;

    my $req = $self->request_setup;

    my @x = eval { 
        return $self->render_group_list unless $req->{group_name};
        my $group = CN::Model->group->fetch(name => $req->{group_name});
        return 404 unless $group;
        return $self->render_group($group) unless $req->{article};
        return $self->redirect_article($group, $req->{article}) unless $req->{year}; 
        return $self->render_article;
    };
    if ($@) {
        return $self->show_error($@)
    }
    return @x;
}


sub cache_info {
    my $self = shift;
    my $setup = $self->request_setup;
    warn Data::Dumper->Dump([\$setup], [qw(setup)]);
    # return {};

    # return {} if $setup->{msg};

    unless ($setup->{group_name}) {
        return { type => 'nntp_group',
                 id   => '_group_list_',
               };
    }

    return {
            type => 'nntp_group',
            id   => join ";", map { $setup->{$_} } qw(group_name year month page article),
           }

}

sub render_group_list {
    my $self = shift;
    my $groups = CN::Model->group->get_groups;
    $self->tpl_param('groups', $groups); 
    return OK, $self->evaluate_template('tpl/group_list.html');
}

sub group {
    my $self = shift;
    return $self->{group} if $self->{group};
    $self->{group} = CN::Model->group->fetch(name => $self->request_setup->{group_name});
}

sub render_group {
    my $self = shift;

    my $group = $self->group;

    my $max = $self->req_param('max') || 0;

    my ($year, $month, $page) = ($self->request_setup->{year}, $self->request_setup->{month}, $self->request_setup->{page});
    warn "YEAR: $year / $month: $month";

    return $self->render_year_overview if $year and ! $month;

    unless ($year) {
        my $newest_article = CN::Model->article->get_articles
            (  query => [ group_id => $group->id, ],
               limit => 1,
               sort_by => 'id desc',
               );
        return 404 unless $newest_article;
        $newest_article = $newest_article->[0];
        ($year, $month) = ($newest_article->received->year, $newest_article->received->month);
    }

    my $month_obj = DateTime->new(year => $year, month => $month, day => 1);

    $self->tpl_param('this_month' => $month_obj);

    my $per_page = 50;

    my $thread_count = $group->get_thread_count($month_obj);
    my $pages = ceil( $thread_count / $per_page);

    $self->tpl_param(page_number => $page);
    $self->tpl_param(pages       => $pages);

    warn "COUNT: $thread_count / PAGES: $pages";

    my $articles = CN::Model->article->get_articles
        (  query => [ group_id => $group->id,
                      received => { lt => $month_obj->clone->add(months => 1) },
                      received => { gt => $month_obj },
                      ],
           limit => $per_page,
           offset => ( $page * $per_page - $per_page ),
           group_by => 'thread_id',
           sort_by => 'id desc',
         );

    $Rose::DB::Object::Manager::Debug = 0;


    $self->tpl_param('previous_month' => $group->previous_month($month_obj));
    $self->tpl_param('next_month'     => $group->next_month($month_obj));

    $self->tpl_param(group => $group);
    $self->tpl_param(articles => $articles);

    return OK, $self->evaluate_template('tpl/article_list.html');
}

sub render_year_overview {
    my $self = shift;
    my $year = $self->request_setup->{year};
    my $group = $self->group;
    my @months;
    for my $month (1..12) { 
        my $month_obj = DateTime->new(year => $year, month => $month, day => 1);
        my $count = 
          CN::Model->article->get_articles_count
              (query => [ group_id  => $group->id,
                          received => { lt => $month_obj->clone->add(months => 1) },
                          received => { gt => $month_obj },
                        ],
              );
        push @months, { month => $month_obj, count => $count } if $count;
    }

    $self->tpl_param('previous_year' => $group->previous_month(DateTime->new(year => $year, month => 1)));
    $self->tpl_param('next_year'     => $group->next_month(    DateTime->new(year => $year, month => 12)));

    $self->tpl_param(group  => $self->group);
    $self->tpl_param(months => \@months);
    $self->tpl_param(year   => $year);
    return OK, $self->evaluate_template('tpl/year.html');
}

sub render_article {
    my $self = shift;

    my $req = $self->request_setup;

    my $article = CN::Model->article->fetch(group_id => $self->group->id,
                                            id       => $req->{article}
                                            );

    return 404 unless $article;

    # should we just return 404? 
    return $self->redirect_article
        unless $article->received->year == $req->{year}
               and $article->received->month == $req->{month};

    $self->tpl_param('article' => $article);
    $self->tpl_param('group'   => $self->group);

    return OK, $self->evaluate_template('tpl/article.html');

}

sub redirect_article {
    my $self = shift;
    my $req = $self->request_setup;

    my $article = CN::Model->article->fetch(group_id => $self->group->id,
                                            id       => $req->{article}
                                            );
    
    return 404 unless $article;

    return $self->redirect($article->uri);

}

sub show_error {
    my ($self, $msg) = @_;
    $self->tpl_param(msg => $msg);
    $self->r->status(500);
    return OK, $self->evaluate_template('tpl/error.html');
}

sub show_nntp_error { shift->show_error('Could not connect to backend NNTP server; please try again later'); }

1;
