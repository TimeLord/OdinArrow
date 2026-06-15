// OdinArrow quickstart — build arrays, run compute kernels, and round-trip an
// Arrow IPC file (which PyArrow / Arrow C++ can read directly).
//
// Run from the repo root with:
//     odin run examples/quickstart -out:/tmp/quickstart
package main

import "base:runtime"
import oa "../src"
import "core:fmt"
import "core:os"
import "core:math/rand"

main :: proc() {
	fmt.println("== OdinArrow quickstart ==")

  //generate_random(1)
  grandom()
  //rrandom()
}

generate_random::proc(num: u32) {
  // Generate a list of 5 random float32 values
  numbers: [1000]u32
  cnt: u32
  cnt = num<200?num:5
  
  /*
  if num > 1000 {
    cnt = 10
  }else {
    cnt=num 
  }
  */

  fmt.printfln(" random numbers to generate: %d", num) 

  for i in 0..<cnt {
    numbers[i] = rand.uint32()
    fmt.println(numbers[i])
  }
}

grandom :: proc() -> (err: runtime.Allocator_Error) {
	//data := rand.perm(4) or_return
	//defer delete(data, context.allocator)
	//fmt.println(data)
	data: [20][10]byte
  for j in 0..<20 {
    for i in 0..<10 {
      data[j][i] = u8(rand.int31_max(50+1))
    }
	  fmt.println(data[j])
  }
	return
}

rrandom :: proc() {
	data: [20]byte
	n := rand.read(data[:])
	fmt.println(n)
	fmt.println(data)
}
