int main(int argc, const char **argv) { @autoreleasepool {
 MulgAttitude *reference=[MulgAttitude new];
 reference.mulgQuaternion=(CMQuaternion){0,0,sin(0.3),cos(0.3)};
 if (argc > 1 && strcmp(argv[1],"copy")==0) {
  MulgAttitude *copy=[reference copy];
  assert(copy != reference);
  assert(fabs(copy.quaternion.z-reference.quaternion.z)<1e-10);
  reference.mulgQuaternion=(CMQuaternion){0,0,0,1};
  assert(fabs(copy.quaternion.z-sin(0.3))<1e-10);
  puts("PASS: copied motion attitude retains its independent virtual quaternion");
 } else {
  MulgAttitude *current=[MulgAttitude new];
  current.mulgQuaternion=(CMQuaternion){0,0,sin(0.5),cos(0.5)};
  [current multiplyByInverseOfAttitude:reference];
  assert(fabs(current.quaternion.z-sin(0.2))<1e-10);
  assert(fabs(current.quaternion.w-cos(0.2))<1e-10);
  assert(fabs(current.yaw-0.4)<1e-10);
  [reference multiplyByInverseOfAttitude:reference];
  assert(fabs(reference.quaternion.z)<1e-10 && fabs(reference.quaternion.w-1)<1e-10);
  puts("PASS: relative motion attitude uses virtual quaternion and self-reference yields identity");
 }
 return 0;
}}
