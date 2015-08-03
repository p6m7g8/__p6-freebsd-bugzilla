bugz=bugz

_pr_dir () {
  local pr=$1

  local d=/tmp/$USER/freebsd/$pr
  if [ ! -d $d ]; then
    mkdir -p $d
  fi

  echo $d
}

_port_from_pr () {
  local d=$1

  local title=$(grep Title $d/pr | cut -d: -f 2- | sed -e 's,^ *,,')
  local port=$(echo $title | egrep -o "[_a-zA-Z0-9\-]*/[_a-zA-Z0-9\-]*" | head -1)

  echo $port
}

_svn_or_git () {

  local vc
  if [ -d $PORTSDIR/.git ]; then
    vc=git
  elif [ -d $PORTSDIR/.svn ]; then
    vc=svn
  else
    echo "Unable to determine checkout type of $PORTSDIR.  Only svn/git supported"
    exit 1
  fi

  echo $vc
}

_delta_generate () {
  local port_dir=$1
  local delta_file=$2

  local vc=$(_svn_or_git)

  if [ x"$vc" = x"git" ]; then
    (cd $PORTSDIR ; git diff $port_dir > $delta_file)
  else
    (cd $PORTSDIR ; svn diff $port_dir > $delta_file)
  fi
}

_update_str () {
  local delta_file=$1
  local prefix="$2"

  local str=""
  local cv=$(grep -c '^[+-]PORTVERSION' $delta_file)
  if [ $cv -eq 2 ]; then
      local oldv=$(awk '/^-PORTVERSION/ { print $2 }'  $delta_file)
      local newv=$(awk '/^\+PORTVERSION/ { print $2 }' $delta_file)
      [ $oldv != $newv ] && str="${prefix}update $oldv->$newv"
  fi

  echo $str
}

_maintainer_str () {
  local delta_file=$1
  local prefix="$2"

  local str=""
  local cm=$(grep -c '^[+-]MAINTAINER' $delta_file)
  if [ $cm -eq 2 ]; then
      local oldm=$(awk '/^-MAINTAINER/ { print $2 }'  $delta_file)
      local newm=$(awk '/^\+MAINTAINER/ { print $2 }' $delta_file)
      [ $oldm != $newm ] && str="${prefix}change maintainer $oldm->$newm"
  fi

  echo $str
}

_portrevision_str () {
  local delta_file=$1
  local prefix="$2"

  local str=""
  local cpr=$(grep -c '^[+-]PORTREVISION' $delta_file)
  if [ $cpr -eq 2 ]; then
      local oldpr=$(awk '/^-PORTREVISION/ { print $2 }'  $delta_file)
      local newpr=$(awk '/^\+PORTREVISION/ { print $2 }' $delta_file)
      [ $oldpr != $newpr -a $oldpr = $(($newpr-1)) ] && str="${prefix}bump portrevision"
  fi

  echo $str
}

_noarch_str () {
  local delta_file=$1
  local prefix="$2"

  local str=""
  local cna=$(grep -c '^[+-]NO_ARCH' $delta_file)
  if [ $cna -eq 1 ]; then
      local newna=$(awk '/^\+NO_ARCH/ { print $2 }' $delta_file)
      [ -n "$newna" ] && str="${prefix}Set NO_ARCH"
  fi

  echo $str
}

_license_str () {
  local delta_file=$1
  local prefix="$2"

  local str=""
  local cl=$(grep -c '^[+-]LICENSE' $delta_file)
  if [ $cl -eq 1 ]; then
      local newl=$(awk '/^\+LICENSE/ { print $2 }' $delta_file)
      [ -n "$newl" ] && str="${prefix}Add LICENSE"
  fi

  echo $str
}

_uses_str () {
  local delta_file=$1
  local prefix="$2"

  local str=""
  local ul=$(grep -c '^[+-]USES' $delta_file)
  if [ $ul -gt 0 ]; then
      local oldul=$(awk -F= '/^-USES/ { print $2 }'  $delta_file)
      local newul=$(awk -F= '/^\+USES/ { print $2 }' $delta_file)

      local interesting=$(echo $oldul $newul | sort | uniq -c | sed -e 's,^ *,,' | awk '/^1/ { print $2 }')

      local converts=
      for use in $interesting; do
        if [ "${interesting#*$use}" != "$interesting" ]; then
            converts="$converts, $use"
        fi
      done
      str="${prefix}Convert to USES $(echo $converts | sed -e 's/^, //')"
  fi

  echo $str
}

_title_generate () {
  local port_dir=$1
  local delta_file=$2

  local title
  if [ -z "$delta_file" ]; then
    local comment=$(cd $PORTSDIR/$port_dir ; make -V COMMENT)
    title="[new port]: $port_dir - $comment"
  else
    if [ -z "$(cat $delta_file)" ]; then
      title=""
    else
      local maintainer=$(cd $PORTSDIR/$port_dir ; make -V MAINTAINER)
      [ $REPORTER = $maintainer ] && title="(maintainer) "

      title="$title[patch]: $port_dir "

      local ustr=$(_update_str $delta_file)
      [ -n "$ustr" ] && title="$title , $ustr"

      local mstr=$(_maintainer_str $delta_file)
      [ -n "$mstr" ] && title="$title , $mstr"
    fi
  fi

  echo "$title"
}

_is_new_port () {
  local port_dir=$1

  local vc=$(_svn_or_git)
  if [ x"$vc" = x"git" ]; then
    if $(cd $PORTSDIR && git ls-files --error-unmatch $port_dir >/dev/null 2>&1); then
      echo 0
    else
      echo 1
    fi
  else
    if $(cd $PORTSDIR && svn ls $port_dir >/dev/null 2>&1); then
      echo 0
    else
      echo 1
    fi
  fi
}

_append_desc () {
  local desc_file=$1
  local str="$2"

  [ x"$str" != x"" ] && echo "$str" >> $desc_file
}

_description_get () {
  local port_dir=$1
  local title="$2"
  local f_n=$3
  local desc_file=$4
  local delta_file=$5

  local description
  if echo $title | grep -q "new"; then
    if [ ! -e $PORTSDIR/$port_dir/pkg-descr ]; then
      echo "$PORTSDIR/$port_dir/pkg-descr does not exist!" >2
    else
      cat $PORTSDIR/$port_dir/pkg-descr >> $desc_file
    fi
  else
    echo "$title" | sed -e 's,.*:,,' -e 's/ , /: /' >> $desc_file
    echo >> $desc_file
    _append_desc $desc_file "$(_update_str       $delta_file "- ")"
    _append_desc $desc_file "$(_maintainer_str   $delta_file "- ")"
    _append_desc $desc_file "$(_portrevision_str $delta_file "- ")"
    _append_desc $desc_file "$(_license_str      $delta_file "- ")"
    _append_desc $desc_file "$(_uses_str         $delta_file "- ")"
    _append_desc $desc_file "$(_noarch_str       $delta_file "- ")"

    if [ $f_n -ne 1 ]; then
      $EDITOR $desc_file > /dev/tty
    fi
  fi
  description="$desc_file"

  . ${BZ_SCRIPTDIR}/_version.sh
  echo >> $desc_file
  echo "--" >> $desc_file
  echo "Generated by ports-mgmt/freebsd-bugzilla-cli - v${BZ_VERSION}." >> $desc_file

  echo "$description"
}

_days_since () {
  local date=$1

  local ethen=$(date -j -f "%Y%m%d" "$date" "+%s")
  local enow=$(date -j -f "%a %b %d %T %Z %Y" "`date`" "+%s")
  local days=$(printf "%.0f" $(echo "scale=2; ($enow - $ethen)/(60*60*24)" | bc))

  echo $days
}

_days_since_action () {
  local d=$1

  local json=$(grep ^flags $d/pr | sed -e "s,^flags       :,,")

  local created=$(_json_find_key_value "creation_date" "$json" 1)
  local modified=$(_json_find_key_value "modification_date" "$json" 1)
  local status=$(_json_find_key_value "status" "$json")

  case $status in
    "+") echo 0 ;;
    *)   echo $(_days_since $created) ;;
  esac
}

_json_find_key_value () {
  local key=$1
  local json="$2"
  local f_d=${3:-0}

  local pair=$(echo "$json" | awk -F"," -v k="$key" '{ gsub(/{|}/,"") for(i=1;i<=NF;i++){if($i~k){print $i}}}')
  local v=$(echo $pair | awk -F: '{ print $2 }' | sed -e "s,',,g" -e 's, *,,g')

  if [ $f_d -eq 1 ]; then
    echo "$v" | sed -e 's,<DateTime,,' -e 's,T.*,,'
  else
    echo "$v"
  fi
}

_field_changed () {
  local field=$1
  local orig_file=$2
  local new_file=$3

  local old=$(awk "/^$field/ { print }" $orig_file | head -1 | cut -d: -f 2-)
  local new=$(awk "/^$field/ { print }" $new_file  | head -1 | cut -d: -f 2-)

  if [ x"$old" != x"$new" ]; then
    echo $new
  fi
}
