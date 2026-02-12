import { Module, Controller, Get } from '@nestjs/common';

@Controller()
class AppController {
  @Get('health')
  getHealth() {
    return { ok: true };
  }
}

@Module({
  imports: [],
  controllers: [AppController],
  providers: [],
})
export class AppModule {}
