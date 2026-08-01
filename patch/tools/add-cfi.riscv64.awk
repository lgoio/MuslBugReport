# Insert GAS CFI directives ("control frame information") into riscv64 asm

BEGIN {
  # don't put CFI data in the .eh_frame ELF section (which we don't keep)
  print ".cfi_sections .debug_frame"

  # only emit CFI directives inside a function
  in_function = 0

  # emit .loc directives with line numbers from original source
  printf ".file 1 \"%s\"\n", ARGV[1]
  line_number = 0
}

function adjust_sp_offset(delta) {
  if (in_function)
    printf ".cfi_adjust_cfa_offset %d\n", delta
}

{
  line_number = line_number + 1


  # clean the input up before doing anything else
  # delete comments
  gsub(/(#).*/, "")

  # canonicalize whitespace
  gsub(/[ \t]+/, " ") # mawk doesn't understand \s
  gsub(/ *, */, ",")
  gsub(/ *: */, ": ")
  gsub(/ $/, "")
  gsub(/^ /, "")

  # A label may share the line with the instruction it marks. The rules below
  # match on this, so they do not have to care either way, while the line
  # itself is still printed with its label intact.
  insn = $0
  sub(/^[a-zA-Z0-9_]+: /, "", insn)
}

# check for assembler directives which we care about
/^\.(section|data|text)/ {
  # a .cfi_startproc/.cfi_endproc pair should be within the same section
  # otherwise, clang will choke when generating ELF output
  if (in_function) {
    print ".cfi_endproc"
    in_function = 0
  }
}
/^\.type [a-zA-Z0-9_]+,%function/ {
  functions[substr($2, 1, length($2)-10)] = 1
}
# not interested in assembler directives beyond this, just pass them through
/^\./ {
  print
  next
}

/^[a-zA-Z0-9_]+:/ {
  label = substr($1, 1, length($1)-1) # drop trailing :

  if (functions[label]) {
    if (in_function)
      print ".cfi_endproc"

    in_function = 1
    print ".cfi_startproc"

    for (register in saved)
      delete saved[register]
  }

  # an instruction may follow on the same line, so continue processing
}


/^$/ { next }

{
  printf ".loc 1 %d\n", line_number
  print
}

# KEEPING UP WITH THE STACK POINTER
# The only form this source tree uses is "add sp,sp,-n" / "addi sp,sp,n".
#
insn ~ /^addi? sp,sp,-?[0-9]+$/ {
  if (in_function) {
    n = insn
    sub(/^addi? sp,sp,/, "", n)
    adjust_sp_offset(-(n + 0))
  }
}

# TRACKING REGISTER VALUES FROM THE PREVIOUS STACK FRAME
# "sd ra,n(sp)" and friends put a register from the caller on the stack.
#
insn ~ /^(sd|sw) [a-z0-9]+,[0-9]+\(sp\)$/ {
  if (in_function) {
    register = substr(insn, index(insn, " ")+1, index(insn, ",")-index(insn, " ")-1)
    offset = substr(insn, index(insn, ",")+1)
    sub(/\(sp\)$/, "", offset)
    if (!saved[register]) {
      printf ".cfi_rel_offset %s,%d\n", register, offset+0
      saved[register] = 1
    }
  }
}


END {
  if (in_function)
    print ".cfi_endproc"
}
