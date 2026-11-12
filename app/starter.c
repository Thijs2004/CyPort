/* CyPort with several game versions: the app's executable. The shim (MacShimMain, shim/MacShim.m) picks the game
   version that fits the game data, loads its game program (Games/<version>/CyberpunkGame.dylib) and runs its main(). */
int MacShimMain(int argc, char **argv);
int main(int argc, char **argv) { return MacShimMain(argc, argv); }
