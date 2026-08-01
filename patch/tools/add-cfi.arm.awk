# Insert GAS CFI directives ("control frame information") into 32-bit ARM asm

BEGIN {
  # don't put CFI data in the .eh_frame ELF section (which we don't keep)
  print ".cfi_sections .debug_frame"

  # only emit CFI directives inside a function
  in_function = 0

  # emit .loc directives with line numbers from original source
  printf ".file 1 \"%s\"\n", ARGV[1]
  line_number = 0

  # set between a stack restore and the return that follows it, so the two
  # halves of .cfi_remember_state/.cfi_restore_state always pair up
  remembered = 0
}

function adjust_sp_offset(delta) {
  if (in_function)
    printf ".cfi_adjust_cfa_offset %d\n", delta
}

# r0-r15 by number, so a register list can be sorted into transfer order
function regnum(register) {
  if (register == "sl") return 10
  if (register == "fp") return 11
  if (register == "ip") return 12
  if (register == "sp") return 13
  if (register == "lr") return 14
  if (register == "pc") return 15
  sub(/^r/, "", register)
  return register+0
}

# {r4,r5,r6,r7} and {r4-r7} both mean the same four registers. Fills regs[]
# with their numbers in ascending order and returns how many there are - stm
# and ldm always transfer in register order, whatever order they are written.
function reglist(str,   i, j, n, m, items, range, out, count, tmp) {
  match(str, /\{[^}]*\}/)
  str = substr(str, RSTART+1, RLENGTH-2)
  n = split(str, items, ",")
  count = 0
  for (i = 1; i <= n; i++) {
    if (index(items[i], "-")) {
      split(items[i], range, "-")
      for (j = regnum(range[1]); j <= regnum(range[2]); j++)
        out[++count] = j
    } else {
      out[++count] = regnum(items[i])
    }
  }
  for (i = 2; i <= count; i++) {          # insertion sort, lists are tiny
    tmp = out[i]
    for (j = i-1; j >= 1 && out[j] > tmp; j--)
      out[j+1] = out[j]
    out[j+1] = tmp
  }
  for (i = 1; i <= count; i++)
    regs[i] = out[i]
  return count
}

# The generator's own idea of which registers still hold the caller's value has
# to follow .cfi_remember_state/.cfi_restore_state, or the state it assumes and
# the state the assembler assumes drift apart after the first return path.
function snapshot(   register) {
  for (register in saved_at_remember) delete saved_at_remember[register]
  for (register in dirty_at_remember) delete dirty_at_remember[register]
  for (register in saved) saved_at_remember[register] = 1
  for (register in dirty) dirty_at_remember[register] = 1
}
function rollback(   register) {
  for (register in saved) delete saved[register]
  for (register in dirty) delete dirty[register]
  for (register in saved_at_remember) saved[register] = 1
  for (register in dirty_at_remember) dirty[register] = 1
}

{
  line_number = line_number + 1


  # clean the input up before doing anything else
  # delete comments
  gsub(/(@|\/\/).*/, "")

  # canonicalize whitespace
  gsub(/[ \t]+/, " ") # mawk doesn't understand \s
  gsub(/ *, */, ",")
  gsub(/ *: */, ": ")
  gsub(/ $/, "")
  gsub(/^ /, "")

  # A label may share the line with the instruction it marks - "1: mov fp,#0".
  # The rules below match on this, so they do not have to care either way,
  # while the line itself is still printed with its label intact.
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
    remembered = 0
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
    remembered = 0
    print ".cfi_startproc"

    for (register in saved)
      delete saved[register]
    for (register in dirty)
      delete dirty[register]
  }

  # an instruction may follow on the same line, so continue processing
}


/^$/ { next }

{
  printf ".loc 1 %d\n", line_number
  print
}

# KEEPING UP WITH THE STACK POINTER
# sp is only ever adjusted by a push or a pop in this source tree; there is no
# "sub sp,sp,#n" anywhere, so anything else touching sp is left alone on
# purpose rather than guessed at.
#
insn ~ /^(push \{|stmfd sp!,\{|stmdb sp!,\{)/ {
  if (in_function) {
    count = reglist(insn)
    adjust_sp_offset(4 * count)

    # A pushed register keeps the caller's value if nothing has overwritten it
    # yet, and then the copy on the stack is the one to report one level up.
    for (i = 1; i <= count; i++) {
      if (!saved[regs[i]] && !dirty[regs[i]]) {
        printf ".cfi_rel_offset r%d,%d\n", regs[i], 4 * (i-1)
        saved[regs[i]] = 1
      }
    }
  }
}

insn ~ /^(pop \{|ldmfd sp!,\{|ldmia sp!,\{)/ {
  if (in_function) {
    # The pop belongs to one return path, but the instructions after it may
    # belong to another that never popped - __cp_cancel in syscall_cp.s and the
    # child half of clone.s are both reached with the registers still saved.
    # Bracketing the restore keeps those paths on the pushed state instead of
    # inheriting this one.
    if (!remembered) {
      print ".cfi_remember_state"
      snapshot()
      remembered = 1
    }
    count = reglist(insn)
    adjust_sp_offset(-4 * count)
    for (i = 1; i <= count; i++) {
      if (saved[regs[i]]) {
        printf ".cfi_restore r%d\n", regs[i]
        delete saved[regs[i]]
      }
    }
  }
}

# End of a path: a return, or a tail call that never comes back. Conditional
# branches are deliberately not matched - they do not end anything.
insn ~ /^(bx lr|bx r14|mov pc,lr|b [a-zA-Z0-9_]+|b [0-9]+[bf])$/ {
  if (in_function && remembered) {
    print ".cfi_restore_state"
    rollback()
    remembered = 0
  }
}

# IF REGISTER VALUES ARE UNCEREMONIOUSLY TRASHED
# ...then we want to know about it. Not an exhaustive list of instructions that
# can overwrite an inherited register, just the ones this source tree uses.
function trashed(register,   n) {
  n = regnum(register)
  if (in_function && !saved[n] && !dirty[n])
    printf ".cfi_undefined r%d\n", n
  dirty[n] = 1
}
insn ~ /^(mov|mvn|add|sub|rsb|and|orr|eor|bic|lsl|lsr|asr|mul|ldr) [a-z0-9]+,/ {
  if (in_function)
    trashed(substr(insn, index(insn, " ")+1, index(insn, ",")-index(insn, " ")-1))
}
# ldm without a "!" writes registers without touching sp
insn ~ /^ldm(fd|ia|db|ea)? [a-z0-9]+,\{/ {
  if (in_function) {
    count = reglist(insn)
    for (i = 1; i <= count; i++)
      trashed("r" regs[i])
  }
}

# Zeroing the frame pointer is musl's own marker for the end of a thread stack -
# clone.s does it in the child so frame-pointer unwinders stop there. Say the
# same thing in CFI, otherwise a debugger keeps going into whatever the
# registers happen to hold and reports __clone over and over.
insn ~ /^mov fp,#?0$/ {
  if (in_function)
    print ".cfi_undefined r14"
}


END {
  if (in_function)
    print ".cfi_endproc"
}
