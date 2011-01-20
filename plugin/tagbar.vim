" ============================================================================
" File:        tagbar.vim
" Description: List the current file's tags in a sidebar, ordered by class etc
" Maintainer:  Jan Larres <jan@majutsushi.net>
" Licence:     Vim licence
" Website:     http://github.com/majutsushi/tagbar
" Note:        This plugin was heavily inspired by the 'Taglist' plugin by
"              Yegappan Lakshamanan and uses some small portions of code from
"              it.
" ============================================================================

if &cp || exists('g:loaded_tagbar')
    finish
endif

if !exists('*system')
    echomsg 'Tagbar: No system() function available, skipping plugin'
    finish
endif

if !exists('g:tagbar_ctags_bin')
    if executable('ctags-exuberant')
        let g:tagbar_ctags_bin = 'ctags-exuberant'
    elseif executable('exctags')
        let g:tagbar_ctags_bin = 'exctags'
    elseif executable('ctags')
        let g:tagbar_ctags_bin = 'ctags'
    elseif executable('ctags.exe')
        let g:tagbar_ctags_bin = 'ctags.exe'
    elseif executable('tags')
        let g:tagbar_ctags_bin = 'tags'
    else
        echomsg 'Tagbar: Exuberant ctags not found, skipping plugin'
        finish
    endif
endif

let g:loaded_tagbar = 1

if !exists('g:tagbar_left')
    let g:tagbar_left = 0
endif

if !exists('g:tagbar_width')
    let g:tagbar_width = 40
endif

if !exists('g:tagbar_types')
    let g:tagbar_types = {}
endif

if !exists('g:tagbar_autoclose')
    let g:tagbar_autoclose = 0
endif

if !exists('g:tagbar_sort')
    let g:tagbar_sort = 1
endif

function! s:InitTypes()
    " Dictionary of the already processed files, index by file name with
    " complete path.
    " The entries are again dictionaries with the following fields:
    " - mtime: File modification time
    " - ftype: The vim file type
    " - tags:  List of the tags that are present in the file, sorted
    "          according to the value of 'g:tagbar_sort'
    " - fline: Dictionary of the tags, indexed by line number in the file
    " - tline: Dictionary of the tags, indexed by line number in the tagbar
    let s:known_files = {}

    let s:known_types = {}

    let type_cpp = {}
    let type_cpp.ctagstype = 'c++'
    let type_cpp.scopes    = ['namespace', 'class', 'struct']
    let type_cpp.sro       = '::'
    let type_cpp.kinds     = [
        \ 'd:macros',
        \ 'n:namespaces',
        \ 'c:classes',
        \ 's:structs',
        \ 't:typedefs',
        \ 'g:enum',
        \ 'u:unions',
        \ 'p:prototypes',
        \ 'f:functions',
        \ 'm:members',
        \ 'v:variables'
    \ ]
    let type_cpp.kind2scope = {
        \ 'n' : 'namespace',
        \ 'c' : 'class',
        \ 's' : 'struct'
    \ }
    let type_cpp.scope2kind = {
        \ 'namespace' : 'n',
        \ 'class'     : 'c',
        \ 'struct'    : 's'
    \ }
    let s:known_types.cpp = type_cpp

    let type_python = {}
    let type_python.ctagstype = 'python'
    let type_python.scopes    = ['class', 'function']
    let type_python.sro       = '.'
    let type_python.kinds     = [
        \ 'i:imports',
        \ 'c:classes',
        \ 'f:functions',
        \ 'm:members',
        \ 'v:variables'
    \ ]
    let type_python.kind2scope = {
        \ 'c' : 'class',
        \ 'f' : 'function',
        \ 'm' : 'function'
    \ }
    let type_python.scope2kind = {
        \ 'class'    : 'c',
        \ 'function' : 'f'
    \ }
    let s:known_types.python = type_python

    call extend(s:known_types, g:tagbar_types)

    " Create a dictionary of the kind order for fast
    " access in sorting functions
    for type in values(s:known_types)
        let i = 0
        let type.kinddict = {}
        for kind in type.kinds
            let type.kinddict[kind[0]] = i
            let i += 1
        endfor
    endfor
endfunction

call s:InitTypes()

function! s:ToggleWindow()
    let tagbarwinnr = bufwinnr("__Tagbar__")
    if tagbarwinnr != -1
        call s:CloseWindow()
        return
    endif

    call s:OpenWindow()
endfunction

function! s:OpenWindow()
    " If the tagbar window is already open jump to it
    let tagbarwinnr = bufwinnr('__Tagbar__')
    if tagbarwinnr != -1 && winnr() != tagbarwinnr
"        execute tagbarwinnr . 'wincmd w'
        return
    endif

    let openpos = g:tagbar_left ? 'topleft vertical ' : 'botright vertical '
    exe 'silent! keepalt ' . openpos . g:tagbar_width . 'split ' . '__Tagbar__'

    setlocal noreadonly " in case the "view" mode is used
    setlocal buftype=nofile
    setlocal bufhidden=delete
    setlocal noswapfile
    setlocal nobuflisted
    setlocal nomodifiable
    setlocal filetype=tagbar
    setlocal nolist
    setlocal nonumber
    setlocal nowrap
    setlocal winfixwidth

    if exists('+relativenumber')
        setlocal norelativenumber
    endif

    setlocal foldenable
    setlocal foldminlines=0
    setlocal foldmethod=manual
    setlocal foldlevel=9999
    setlocal foldcolumn=1
    setlocal foldtext=v:folddashes.getline(v:foldstart)

    " Variable for saving the current file for functions that are called from
    " the tagbar window
    let s:current_file = ''
    let s:is_maximized = 0

    syntax match Comment    '^" .*'              " Comments
    syntax match Identifier '^[^: ]\+$'          " Non-scoped kinds
    syntax match Title      '[^:(* ]\+\ze\*\? :' " Scope names
    syntax match Type       ': \zs.*'            " Scope types
    syntax match SpecialKey '(.*)'               " Signatures
    syntax match NonText    '\*\ze :'            " Pseudo-tag identifiers

    if has('balloon_eval')
        setlocal balloonexpr=TagbarBalloonExpr()
        set ballooneval
    endif

    let cpoptions_save = &cpoptions
    set cpoptions&vim

    nnoremap <script> <silent> <buffer> s       :call <SID>ToggleSort()<CR>
    nnoremap <script> <silent> <buffer> <CR>    :call <SID>JumpToTag()<CR>
    nnoremap <script> <silent> <buffer> <2-LeftMouse>
                                              \ :call <SID>JumpToTag()<CR>
    nnoremap <script> <silent> <buffer> <Space> :call <SID>ShowPrototype()<CR>
    nnoremap <script> <silent> <buffer> x       :call <SID>ZoomWindow()<CR>
    nnoremap <script> <silent> <buffer> q       :close<CR>

    augroup TagbarAutoCmds
        autocmd!
        autocmd BufEnter   __Tagbar__ nested call s:QuitIfOnlyWindow()
        autocmd BufUnload  __Tagbar__ call s:CleanUp()
        autocmd CursorHold __Tagbar__ call s:ShowPrototype()

"        autocmd TabEnter * silent call s:Tlist_Refresh_Folds()
        autocmd BufEnter,CursorHold * silent call s:AutoUpdate(
                    \ fnamemodify(bufname('%'), ':p'))
    augroup END

    let &cpoptions = cpoptions_save

    execute 'wincmd p'
endfunction

function! s:CloseWindow()
    let tagbarwinnr = bufwinnr('__Tagbar__')
    if tagbarwinnr == -1
        return
    endif

    if winnr() == tagbarwinnr
        if winbufnr(2) != -1
            " Other windows are open, only close the tagbar one
            close
        endif
    else
        " Go to the tagbar window, close it and then come back to the
        " original window
        let curbufnr = bufnr('%')
        execute tagbarwinnr . 'wincmd w'
        close
        " Need to jump back to the original window only if we are not
        " already in that window
        let winnum = bufwinnr(curbufnr)
        if winnr() != winnum
            exe winnum . 'wincmd w'
        endif
    endif
endfunction

function! s:ZoomWindow()
    if s:is_maximized
        execute 'vert resize ' . g:tagbar_width
        let s:is_maximized = 0
    else
        vert resize
        let s:is_maximized = 1
    endif
endfunction

function! s:CleanUp()
    silent! autocmd! TagbarAutoCmds
endfunction

function! s:QuitIfOnlyWindow()
    " Before quitting Vim, delete the tagbar buffer so that
    " the '0 mark is correctly set to the previous buffer.
    if winbufnr(2) == -1
        " Check if there is more than one tab page
        if tabpagenr('$') == 1
            bdelete
            quit
        else
            close
        endif
    endif
endfunction

function! s:AutoUpdate(fname)
    call s:RefreshContent(a:fname)

    let tagbarwinnr = bufwinnr('__Tagbar__')
    if tagbarwinnr == -1 || &filetype == 'tagbar'
        return
    endif

    if !has_key(s:known_files, a:fname)
        return
    endif

    let s:current_file = a:fname

    call s:HighlightTag(a:fname)
endfunction

function! s:RefreshContent(fname)
    " Don't do anything if we're in the tagbar window
    if &filetype == 'tagbar'
        return
    endif

    if has_key(s:known_files, a:fname)
        if s:known_files[a:fname].mtime != getftime(a:fname)
            call s:ProcessFile(a:fname, &filetype)
        endif
    else
        call s:ProcessFile(a:fname, &filetype)
    endif

    let tagbarwinnr = bufwinnr('__Tagbar__')

    if tagbarwinnr != -1
        call s:RenderContent(a:fname, &filetype)
    endif
endfunction

function! s:IsValidFile(fname, ftype)
    if a:fname == '' || a:ftype == ''
        return 0
    endif

    if !filereadable(a:fname)
        return 0
    endif

    if !has_key(s:known_types, a:ftype)
        return 0
    endif

    return 1
endfunction

function! s:ProcessFile(fname, ftype)
    if !s:IsValidFile(a:fname, a:ftype)
        return
    endif

    let typeinfo = s:known_types[a:ftype]

    let ctags_args  = ' -f - '
    let ctags_args .= ' --format=2 '
    let ctags_args .= ' --excmd=pattern '
    let ctags_args .= ' --fields=nksSaz '
    let ctags_args .= ' --extra= '
    let ctags_args .= ' --sort=yes '

    let ctags_type = typeinfo.ctagstype

    let ctags_kinds = ""
    for kind in typeinfo.kinds
        let [short, full] = split(kind, ':')
        let ctags_kinds .= short
    endfor

    let ctags_args .= ' --language-force=' . ctags_type .
                    \ ' --' . ctags_type . '-kinds=' . ctags_kinds . ' '

    let ctags_cmd = g:tagbar_ctags_bin . ctags_args . shellescape(a:fname)
    let ctags_output = system(ctags_cmd)

    if v:shell_error
        let msg = 'Tagbar: Could not generate tags for ' . a:fname
        call s:PrintWarningMsg(msg)
        if !empty(ctags_output)
            call s:PrintWarningMsg(ctags_output)
        endif
        return
    endif

    let fileinfo = {}
    let fileinfo.mtime = getftime(a:fname)

    let rawtaglist = split(ctags_output, '\n\+')

    let fileinfo.ftype = a:ftype
    let fileinfo.tags  = []
    let fileinfo.fline = {}
    let fileinfo.tline = {}

    for line in rawtaglist
        let parts = split(line, ';"')
        if len(parts) == 2 " Is a valid tag line
            let taginfo = s:ParseTagline(parts[0], parts[1])
            let fileinfo.fline[taginfo.fields.line] = taginfo
            call add(fileinfo.tags, taginfo)
        endif
    endfor

    if has_key(typeinfo, 'scopes') && !empty(typeinfo.scopes)
        " Extract top-level scopes, removing them from the tag list
        let scopedtags = filter(copy(fileinfo.tags),
                              \ 's:IsTopLevelScopeDef(typeinfo, v:val)')
        call filter(fileinfo.tags, '!s:IsTopLevelScopeDef(typeinfo, v:val)')

        " Add children
        for tag in scopedtags
            let scopetype = typeinfo.kind2scope[tag.fields.kind]
            let tag.children = s:GetChildTags(fileinfo.tags, scopetype,
                                            \ '', tag.name, typeinfo)
        endfor

        call s:AddPseudoTags(fileinfo.tags, typeinfo)

        call extend(fileinfo.tags, scopedtags)
    endif

    " Script-local variable needed since compare functions can't
    " take extra arguments
    let s:compare_typeinfo = typeinfo

    if g:tagbar_sort
        call s:SortTags(fileinfo.tags, 's:CompareByKind')
    else
        call s:SortTags(fileinfo.tags, 's:CompareByLine')
    endif

    let s:known_files[a:fname] = fileinfo
endfunction

" name<TAB>file<TAB>expattern;"fields
" fields: <TAB>name:value
" fields that are always present: kind, line
function! s:ParseTagline(part1, part2)
    let taginfo = {}

    let basic_info      = split(a:part1, '\t')
    let taginfo.name    = basic_info[0]
    let taginfo.file    = basic_info[1]

    let pattern = basic_info[2]
    let start   = 2 " skip the slash and the ^
    let end     = strlen(pattern) - 1
    if pattern[end - 1] == '$'
        let end -= 1
        let dollar = '\$'
    else
        let dollar = ''
    endif
    let pattern           = strpart(pattern, start, end - start)
    let taginfo.pattern   = '\V\^' . pattern . dollar
    let prototype         = substitute(pattern,   '^[[:space:]]\+', '', '')
    let prototype         = substitute(prototype, '[[:space:]]\+$', '', '')
    let taginfo.prototype = prototype

    let taginfo.fields = {}
    let fields = split(a:part2, '\t')
    for field in fields
        " can't use split() since the value can contain ':'
        let delimit             = stridx(field, ':')
        let key                 = strpart(field, 0, delimit)
        let val                 = strpart(field, delimit + 1)
        let taginfo.fields[key] = val
    endfor

    return taginfo
endfunction

" Pseudo-tags are tags that have children in the current file but but don't
" appear themselves in it as a tag. This can happen for example with C++
" classes that are defined in header files but implemented in .cpp files or
" with anonymous namespaces.
function! s:AddPseudoTags(tags, typeinfo)
    let pseudotags = []

    for scope in a:typeinfo.scopes
        call s:AddPseudoChildren(a:tags, pseudotags, '', scope, 1, a:typeinfo)
    endfor

    call extend(a:tags, pseudotags)
endfunction

" This is probably the most cryptic function since it has to deal with things
" that aren't actually there and several corner cases. Try not to think about
" it too much.
function! s:AddPseudoChildren(tags, pseudotags, pcomplpath,
                            \ scope, depth, typeinfo)
    let is_orphan = 'has_key(v:val.fields, a:scope)'
    if !empty(a:pcomplpath)
        let is_orphan .= ' && s:PseudoPathMatches(v:val.fields[a:scope],
                                                \ a:pcomplpath, a:typeinfo.sro)'
    endif

    " Orphans with the current 'pcomplpath' prefix at the current depth
    let is_cur_orphan = is_orphan . ' && len(split(v:val.fields[a:scope],
                                                 \ a:typeinfo.sro)) == a:depth'
    let curorphans    = filter(copy(a:tags), is_cur_orphan)
    if !empty(curorphans)
        call filter(a:tags, '!(' . is_cur_orphan . ')')
    endif

    let is_min_orphan = is_orphan . ' && len(split(v:val.fields[a:scope],
                                                 \ a:typeinfo.sro)) >= a:depth'
    " Orphans with the current 'pcomplpath' prefix and at least the current
    " depth. Since the tags that are at the current depth have already been
    " removed these must be at a lower depth.
    let minorphans    = filter(copy(a:tags), is_min_orphan)

    if empty(curorphans) && empty(minorphans)
        return
    endif

    " Process orphans that are at the current depth
    if !empty(curorphans)
        for orphan in curorphans
            let pcompllength = len(split(a:pcomplpath, a:typeinfo.sro))
            let pseudoname   = substitute(orphan.fields[a:scope],
                                        \ a:pcomplpath, '', '')
            let pseudoname   = substitute(pseudoname,
                                        \ '^' . a:typeinfo.sro, '', '')
            let pseudopath   = split(pseudoname, a:typeinfo.sro)

            let maxplength = a:depth - 1 - pcompllength
            let existing = filter(copy(a:pseudotags),
                                \ 'v:val.name == join(pseudopath[:maxplength],
                                                    \ a:typeinfo.sro)')
            if empty(existing)
                let pseudotag             = {}
                let pseudotag.name        = pseudoname
                let pseudotag.fields      = {}
                let pseudotag.fields.kind = a:typeinfo.scope2kind[a:scope]
                let pseudotag.fields.line = 0
                let pseudotag.children    = [orphan]
                call add(a:pseudotags, pseudotag)
            else
                call add(existing[0].children, orphan)
            endif
        endfor

        for tag in a:pseudotags
            if !has_key(tag, 'children')
                continue
            endif

            if empty(a:pcomplpath)
                let complpath = tag.name
            else
                let complpath = a:pcomplpath . a:typeinfo.sro . tag.name
            endif
            call s:AddPseudoChildren(a:tags, tag.children, complpath,
                                   \ a:scope, a:depth + 1, a:typeinfo)
        endfor
    endif

    " Process orphans that are at a lower depth
    if !empty(minorphans)
        call s:AddPseudoChildren(a:tags, a:pseudotags, a:pcomplpath,
                               \ a:scope, a:depth + 1, a:typeinfo)
    endif
endfunction

function! s:PseudoPathMatches(scopename, pcomplpath, sro)
    let index      = strridx(a:scopename, a:sro)
    let parentpath = strpart(a:scopename, 0, index)
    return parentpath == a:pcomplpath
endfunction

function! s:SortTags(tags, comparemethod)
    call sort(a:tags, a:comparemethod)

    for tag in a:tags
        if has_key(tag, 'children')
            call s:SortTags(tag.children, a:comparemethod)
        endif
    endfor
endfunction

function! s:CompareByKind(tag1, tag2)
    let typeinfo = s:compare_typeinfo

    if typeinfo.kinddict[a:tag1.fields.kind] <
     \ typeinfo.kinddict[a:tag2.fields.kind]
        return -1
    elseif typeinfo.kinddict[a:tag1.fields.kind] >
         \ typeinfo.kinddict[a:tag2.fields.kind]
        return 1
    else
        if a:tag1.name <= a:tag2.name
            return -1
        else
            return 1
        endif
    endif
endfunction

function! s:CompareByLine(tag1, tag2)
    return a:tag1.fields.line - a:tag2.fields.line
endfunction

function! s:RenderContent(fname, ftype)
    let tagbarwinnr = bufwinnr('__Tagbar__')

    if &filetype == 'tagbar'
        let in_tagbar = 1
    else
        let in_tagbar = 0
        execute tagbarwinnr . 'wincmd w'
    endif

    let lazyredraw_save = &lazyredraw
    set lazyredraw

    setlocal modifiable

    silent! %delete _

    if !s:IsValidFile(a:fname, a:ftype)
        silent! put ='- File type not supported -'

        let s:current_file = ''

        setlocal nomodifiable
        let &lazyredraw = lazyredraw_save

        if !in_tagbar
            execute 'wincmd p'
        endif

        return
    endif

    let typeinfo = s:known_types[a:ftype]
    let fileinfo = s:known_files[a:fname]

    " Print tags
    for kind in typeinfo.kinds
        let curtags = filter(copy(fileinfo.tags),
                           \ 'v:val.fields.kind == kind[0]')

        if empty(curtags)
            continue
        endif

        if has_key(typeinfo.kind2scope, kind[0])
            " Scoped tags
            for tag in curtags
                let taginfo = ''

                if tag.fields.line == 0 " Tag is a pseudo-tag
                    let taginfo .= '*'
                endif
                if has_key(tag.fields, 'signature')
                    let taginfo .= tag.fields.signature
                endif
                let taginfo .= ' : ' . typeinfo.kind2scope[kind[0]]

                silent! put =tag.name . taginfo

                " Save the current tagbar line in the tag for easy
                " highlighting access
                let curline                 = line('.')
                let tag.tline               = curline
                let fileinfo.tline[curline] = tag

                for childtag in tag.children
                    call s:PrintTag(childtag, 1, fileinfo, typeinfo)
                endfor

                silent! put _
            endfor
        else
            " Non-scoped tags
            silent! put =strpart(kind, 2)

            for tag in curtags
                let taginfo = ''

                if has_key(tag.fields, 'signature')
                    let taginfo .= tag.fields.signature
                endif

                silent! put ='  ' . tag.name . taginfo

                " Save the current tagbar line in the tag for easy
                " highlighting access
                let curline                 = line('.')
                let tag.tline               = curline
                let fileinfo.tline[curline] = tag
            endfor


            silent! put _
        endif
    endfor

    setlocal nomodifiable

    let &lazyredraw = lazyredraw_save

    if !in_tagbar
        execute 'wincmd p'
    endif
endfunction

function! s:IsTopLevelScopeDef(typeinfo, tag)
    let is_scope_def = 0

    " Does the tag specify a scope?
    if !has_key(a:typeinfo.kind2scope, a:tag.fields.kind)
        return 0
    endif

    " Is the tag not inside of any scopes?
    for scope in a:typeinfo.scopes
        if has_key(a:tag.fields, scope)
            return 0
        endif
    endfor

    return 1
endfunction

function! s:GetChildTags(tags, pscopetype, pscope, pname, typeinfo)
    if empty(a:pscope)
        let curscope = a:pname
    else
        let curscope = a:pscope . a:typeinfo.sro . a:pname
    endif

    " Extract tags that are children of the given tag,
    " removing them from the tag list
    let is_child = 'has_key(v:val.fields, a:pscopetype) &&
                  \ v:val.fields[a:pscopetype] == curscope'
    let childtags = filter(copy(a:tags), is_child)
    call filter(a:tags, '!(' . is_child . ')')

    " Recursively add children
    for tag in childtags
        if has_key(a:typeinfo.kind2scope, tag.fields.kind)
            let curscopetype = a:typeinfo.kind2scope[tag.fields.kind]
            let tag.children = s:GetChildTags(a:tags, curscopetype,
                                            \ curscope, tag.name, a:typeinfo)
        endif
    endfor

    return childtags
endfunction

function! s:PrintTag(tag, depth, fileinfo, typeinfo)
    let taginfo = ''

    if a:tag.fields.line == 0 " Tag is a pseudo-tag
        let taginfo .= '*'
    endif
    if has_key(a:tag.fields, 'signature')
        let taginfo .= a:tag.fields.signature
    endif
    if has_key(a:typeinfo.kind2scope, a:tag.fields.kind)
        let taginfo .= ' : ' . a:typeinfo.kind2scope[a:tag.fields.kind]
    endif

    " Print tag indented according to depth
    silent! put =repeat(' ', a:depth * 2) . a:tag.name . taginfo

    " Save the current tagbar line in the tag for easy
    " highlighting access
    let curline                   = line('.')
    let a:tag.tline               = curline
    let a:fileinfo.tline[curline] = a:tag

    " Recursively print children
    if has_key(a:tag, 'children')
        for childtag in a:tag.children
            call s:PrintTag(childtag, a:depth + 1, a:fileinfo, a:typeinfo)
        endfor
    endif
endfunction

function! s:HighlightTag(fname)
    let fileinfo = s:known_files[a:fname]

    let curline = line('.')

    let tagline = 0

    for line in range(curline, 1, -1)
        if has_key(fileinfo.fline, line)
            let tagline = fileinfo.fline[line].tline
            break
        endif
    endfor

    let eventignore_save = &eventignore
    set eventignore=all

    let tagbarwinnr = bufwinnr('__Tagbar__')
    execute tagbarwinnr . 'wincmd w'

    match none

    if tagline == 0
        execute 1
        call winline()
        execute 'wincmd p'
        let &eventignore = eventignore_save
        return
    endif

    " Go to the line containing the tag
    execute tagline

    if foldclosed('.') != -1
        .foldopen!
    endif

    " Make sure the tag is visible in the window
    call winline()

    let pattern = '/^\%' . tagline . 'l\s*\zs[^( ]\+\ze/'
    execute 'match Search ' . pattern

    execute 'wincmd p'

    let &eventignore = eventignore_save
endfunction

function! s:JumpToTag()
    let taginfo = s:GetTagInfo(line('.'))

    if empty(taginfo)
        return
    endif

    execute 'wincmd p'

    " Jump to the line where the tag is defined. Don't use the search pattern
    " since it doesn't take the scope into account and thus can fail if tags
    " with the same name are defined in different scopes (e.g. classes)
    execute taginfo.fields.line

    " Center the tag in the window
    normal! z.

    if foldclosed('.') != -1
        .foldopen!
    endif

    if g:tagbar_autoclose
        call s:CloseWindow()
    else
        call s:HighlightTag(s:current_file)
    endif
endfunction

function! s:ShowPrototype()
    let taginfo = s:GetTagInfo(line('.'))

    if empty(taginfo)
        return
    endif

    echo taginfo.prototype
endfunction

function! TagbarBalloonExpr()
    let taginfo = s:GetTagInfo(v:beval_lnum)

    if empty(taginfo)
        return
    endif

    return taginfo.prototype
endfunction

" Return the info dictionary of the tag on the specified line. If the line
" does not contain a valid tag (for example because it is empty or only
" contains a pseudo-tag) return an empty dictionary.
function! s:GetTagInfo(linenr)
    if !has_key(s:known_files, s:current_file)
        return {}
    endif

    " Don't do anything in empty and comment lines
    let curline = getline(a:linenr)
    if curline =~ '^\s*$' || curline[0] == '"'
        return {}
    endif

    let fileinfo = s:known_files[s:current_file]

    " Check if there is a tag on the current line
    if !has_key(fileinfo.tline, a:linenr)
        return {}
    endif

    let taginfo = fileinfo.tline[a:linenr]

    " Check if the current tag is not a pseudo-tag
    if taginfo.fields.line == 0
        return {}
    endif

    return taginfo
endfunction

function! s:ToggleSort()
    if !has_key(s:known_files, s:current_file)
        return
    endif

    let curline = line('.')

    let fileinfo = s:known_files[s:current_file]

    match none

    let g:tagbar_sort = !g:tagbar_sort

    let s:compare_typeinfo = s:known_types[fileinfo.ftype]

    if g:tagbar_sort
        call s:SortTags(fileinfo.tags, 's:CompareByKind')
    else
        call s:SortTags(fileinfo.tags, 's:CompareByLine')
    endif

    call s:RenderContent(s:current_file, fileinfo.ftype)

    execute curline
endfunction

function! s:PrintWarningMsg(msg)
    echohl WarningMsg
    echomsg a:msg
    echohl None
endfunction

command! -nargs=0 TagbarToggle call s:ToggleWindow()
command! -nargs=0 TagbarOpen   call s:OpenWindow()
command! -nargs=0 TagbarClose  call s:CloseWindow()

" vim: ts=8 sw=4 sts=4 et foldenable foldmethod=syntax foldcolumn=1
