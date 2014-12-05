package PluginInstaller::CMS;

use strict;
use warnings;
use File::Spec;
use File::Find;
use File::Path;
use File::Basename;
use File::Temp qw( tempfile );
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );

sub _cb_template_source_cfg_plugin {
    my ( $cb, $app, $tmpl ) = @_;
    my $form = <<'MTML';
<__trans_section component="PluginInstaller">
<form method="post" action="<$mt:var name="script_url"$>" id="plugins-install-form">
<table style="width:100%" id="plugin-download-table">
<tr><td>
<input type="text" id="plugin_archive_url" name="plugin_archive_url" value="" class="full-width" style="width:100%" placeholder="<__trans phrase="Enter plugin's URL(ZIP Aechive) to install.">"/></td><td style="width:110px;text-align:right"><button class="save action primary button" type="submit" onclick="return install_from_plugin_archive_url();"><__trans phrase="Install Plugin"></button></td></tr></table>
<input type="hidden" name="__mode" value="install_plugin_from_archive_url" />
<input type="hidden" name="magic_token" value="<$mt:var name="magic_token"$>" />
</form>
<script type="text/javascript">
function install_from_plugin_archive_url(){
    var plugin_archive_url = getByID( 'plugin_archive_url' ).value;
    if ( plugin_archive_url == '' ) {
        alert( '<__trans phrase="Install Plugin">' );
        return false;
    }
    return confirm( '<__trans phrase="Are you sure you want to install this plugin?">' );
}
</script>
</__trans_section>
MTML
    my $search = quotemeta( '<!-- START mt:loop name="plugin_groups" -->' );
    $$tmpl =~ s/($search)/$form $1/s;
    my $msg = <<'MTML';
<mt:setvarblock name="system_msg" append="1">
<__trans_section component="PluginInstaller">
    <mt:if name="request.installed">
      <mtapp:statusmsg
         id="installed"
         class="success">
        <__trans phrase="Plugin '[_1]' installed successfully!" params="<mt:var name="request.installed" escape="html">">
      </mtapp:statusmsg>
     </mt:if>
    <mt:if name="request.install_error">
      <mtapp:statusmsg
         id="install_error"
         class="error">
        <__trans phrase="An error occurred while trying to install the Plugin.">
      </mtapp:statusmsg>
     </mt:if>
</__trans_section>
</mt:setvarblock>
MTML
    $search = quotemeta( '<mt:include name="include/header.tmpl" id="header_include">' );
    $$tmpl =~ s/($search)/$msg $1/s;
}

sub _app_cms_install_plugin_from_archive_url {
    my $app = shift;
    my $component = MT->component( 'PluginInstaller' );
    if ( uc( $app->request_method ) eq 'GET' ) {
        return $app->trans_error( 'Invalid request' );
    }
    $app->validate_magic or
        return $app->trans_error( 'Permission denied.' );
    if ( $app->blog ) {
        $app->return_to_dashboard;
    }
    return $app->trans_error( 'Permission denied.' )
        if !$app->can_do( 'manage_plugins' );
    my $tempdir = MT->config( 'TempDir' );
    my $allow_overwrite = MT->config( 'PluginAllowOverwrite' );
    my $perms = MT->config( 'PluginPerms' ) || 0644;
    my $cgiperms = MT->config( 'PluginCGIPerms' ) || 0755;
    my $toolperms = MT->config( 'PluginToolPerms' ) || 0755;
    my @PluginPath = MT->config( 'PluginPath' );
    my $plugin_dir = $PluginPath[ 0 ];
    my $static_path = MT->config( 'StaticFilePath' );
    $perms = sprintf( '%04d', oct( $perms ) );
    $cgiperms = sprintf( '%04d', oct( $cgiperms ) );
    my ( $fh, $tempfile ) = tempfile( DIR => $tempdir );
    close $fh;
    unlink $tempfile;
    $tempfile = "$tempfile.zip";
    my $url = $app->param( 'plugin_archive_url' );
    my $ua = MT->new_ua( { max_size => undef } );
    my $res = $ua->get( $url, ':content_file' => $tempfile );
    my ( $id, $error );
    if ( $res->is_success ) {
        my ( $invalid, $plugin_exists );
        my $archive = Archive::Zip->new();
        unless ( $archive->read( $tempfile ) == AZ_OK ) {
            return $app->trans_error( $component->translate( 'Cannot read zip archive: [_1]', $tempfile ) );
        }
        my @members = $archive->members();
        my $dir = $tempfile;
        $dir =~ s/\.zip$//;
        my ( $root, $from, $to, $static, $tool );
        my $res = '';
        for my $member( @members ) {
            my $out = $member->fileName;
            $out =~ s!^[/\\]+!!;
            my $basename = File::Basename::basename( $out );
            next if ( $basename =~ /^\./ );
            $out = File::Spec->catfile( $dir, $out );
            if ( $out =~ /config.yaml$/ ) {
                $from = File::Basename::dirname( $out );
                $root = File::Basename::dirname( File::Basename::dirname( $from ) );
                $id = File::Basename::basename( $from );
                $to = File::Spec->catdir( $plugin_dir, $id );
            } elsif ( $out =~ /mt\-static$/ ) {
                $static = $out;
            }
            $archive->extractMemberWithoutPaths( $member->fileName, $out );
            next unless -f $out;
            $out =~ /\.cgi$/i
                ? chmod $cgiperms, $out
                : chmod $perms, $out;
        }
        if (! $from ) {
            $error = 1;
            $invalid = 1;
        }
        my $res;
        if (-d $from ) {
            my $install;
            if (-d $to ) {
                if ( $allow_overwrite ) {
                    File::Path::rmtree( [ $to ] );
                    $install = 1;
                } else {
                    $error = 1;
                }
                $plugin_exists = 1;
            } else {
                $install = 1;
            }
            if ( $install ) {
                $res = File::Copy::Recursive::dirmove( $from, $to );
            }
        } elsif ( -f $from ) {
            $res = File::Copy::move( $from, $to );
        }
        if (! $res ) {
            $error = 1;
        }
        if ( $static && -d $static ) {
            my $plugin_dir = File::Spec->catdir( $static, 'plugins' );
            if (-d $plugin_dir ) {
                $plugin_dir = File::Spec->catdir( $plugin_dir, $id );
                if (-d $plugin_dir ) {
                    my $install;
                    my $plugin_to = File::Spec->catdir( $static_path, 'plugins', $id );
                    if (-d $plugin_to ) {
                        if ( $allow_overwrite ) {
                            File::Path::rmtree( [ $plugin_to ] );
                            $install = 1;
                        } else {
                            $error = 1;
                        }
                        $plugin_exists = 1;
                    } else {
                        $install = 1;
                    }
                    if ( $install ) {
                        $res = File::Copy::Recursive::dirmove( $plugin_dir, $plugin_to );
                    }
                    if (! $res ) {
                        $error = 1;
                    }
                }
            }
        }
        my $tools = File::Spec->catdir( $root, 'tools' );
        if (-d $tools ) {
            my @fromFiles;
            File::Find::find( sub { push( @fromFiles, $File::Find::name ) if (-f $File::Find::name ); },
                $tools );
            my $mt_dir = $app->mt_dir;
            for my $from ( @fromFiles ) {
                my $name = File::Basename::basename( $from );
                my $to = File::Spec->catfile( $mt_dir, 'tools', $name );
                my $install;
                if (-f $to ) {
                    if ( $allow_overwrite ) {
                        unlink $to;
                        $install = 1;
                    } else {
                        $error = 1;
                        $plugin_exists = 1;
                    }
                } else {
                    $install = 1;
                }
                if ( $install ) {
                    $res = File::Copy::move( $from, $to );
                }
                if (! $res ) {
                    $error = 1;
                }
                chmod $toolperms, $to;
            }
        }
        File::Path::rmtree( [ $dir ] );
        unlink $tempfile;
    } else {
        $error = 1;
    }
    if ( $id && (! $error ) ) {
        $app->do_reboot;
        my $author = MT->model( 'author' )->load( undef, { limit => 1 } );
        require MT::Upgrade;
        my $updated = MT::Upgrade->do_upgrade(
            App       => __PACKAGE__,
            DryRun    => undef,
            Install   => 0,
            SuperUser => $author->id,
            CLI       => 1,
        );
        $app->do_reboot;
        return $app->redirect( $app->uri( mode => 'cfg_plugins',
                                   args => { blog_id => '0',
                                             installed => $id } ) );
    } else {
        if (! $id ) {
            $id = 1;
        }
        return $app->redirect( $app->uri( mode => 'cfg_plugins',
                                   args => { blog_id => '0',
                                             install_error => $id } ) );
    }
}

1;