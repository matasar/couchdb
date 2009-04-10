PS1 = 'js> '
PS2 = '..> '
_buffer = ''

while(true) {
  if (_buffer.length == 0) {
    write(PS1)
  } else {
    write(PS2)
  }
  line = readline()
  if (line.length == 0) {
    print("exiting")
    break
  }

  _buffer += line
  if (is_compilable(_buffer)) {
    var value = null
    try {
      value = eval(_buffer)
      if (value)
        print(value)
    } catch(error) {
      print("ERROR: " + error)
    }
    _buffer = ''
  }
}
